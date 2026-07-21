defmodule LongpiWeb.AuthGateTest do
  # Flips the global auth flag, so never async.
  use LongpiWeb.ConnCase, async: false

  alias Longpi.Accounts.Seeder

  setup do
    on_exit(fn ->
      Application.delete_env(:longpi, :auth_enabled)
      # The UI toggle caches its DB setting in persistent_term; scrub it so a
      # set_enabled from one test can't leak into the next.
      :persistent_term.erase({Longpi.Auth, :enabled})
    end)

    :ok
  end

  defp enable_auth, do: Application.put_env(:longpi, :auth_enabled, true)

  describe "auth disabled (the default)" do
    test "SPA and RPC are open", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200)
      assert conn |> get(~p"/rpc/version") |> json_response(200)
    end
  end

  describe "auth enabled" do
    test "SPA pages redirect to /sign-in", %{conn: conn} do
      enable_auth()
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/sign-in"
    end

    test "the redirect remembers where the browser was headed", %{conn: conn} do
      enable_auth()
      conn = get(conn, ~p"/manage/extensions")
      assert redirected_to(conn) == "/sign-in"
      assert get_session(conn, :return_to) == "/manage/extensions"
    end

    test "RPC replies 401 JSON instead of redirecting", %{conn: conn} do
      enable_auth()
      conn = get(conn, ~p"/rpc/version")
      assert json_response(conn, 401)["error"] =~ "authentication"
    end

    test "a signed-in session passes the gate", %{conn: conn} do
      enable_auth()

      conn =
        conn
        |> assign(:current_user, %{id: "u1"})
        |> LongpiWeb.Plugs.RequireAuth.call(mode: :page)

      refute conn.halted
    end

    test "a signed-in page carries a WORKING socket token (the whole handoff)", %{conn: conn} do
      enable_auth()

      # Seed + sign in for real, so the session holds the stored token.
      Application.put_env(:longpi, :bootstrap_users, "sock@example.com:secret123")
      on_exit(fn -> Application.delete_env(:longpi, :bootstrap_users) end)
      :ok = Seeder.run()

      {:ok, user} =
        Longpi.Accounts.User
        |> Ash.Query.for_read(:sign_in_with_password, %{
          email: "sock@example.com",
          password: "secret123"
        })
        |> Ash.read_one(authorize?: false)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)
        |> get(~p"/")

      html = html_response(conn, 200)

      # The layout must embed a token the socket will actually accept —
      # user.__metadata__.token is NOT available on session-loaded requests,
      # so this asserts the session-based handoff end to end.
      assert [_, token] = Regex.run(~r/name="socket-token" content="([^"]+)"/, html)
      assert {:ok, socket_user} = Longpi.Auth.verify_bearer_token(token)
      assert to_string(socket_user.email) == "sock@example.com"
      assert html =~ ~s(name="user-email" content="sock@example.com")
    end

    test "the embed page is gated too", %{conn: conn} do
      enable_auth()
      assert redirected_to(get(conn, ~p"/embed")) == "/sign-in"
    end
  end

  describe "management UI: users & the sign-in toggle" do
    test "enabling sign-in with zero accounts is refused", %{conn: conn} do
      if Ash.count!(Longpi.Accounts.User, authorize?: false) == 0 do
        conn = post(conn, ~p"/rpc/auth", %{"enabled" => true})
        assert json_response(conn, 422)["error"] =~ "add a user first"
        refute Longpi.Auth.enabled?()
      end
    end

    test "add user → toggle on (live) → toggle off", %{conn: conn} do
      assert %{"ok" => true} =
               conn
               |> post(~p"/rpc/users", %{"email" => "ui@example.com", "password" => "secret123"})
               |> json_response(200)

      assert %{"users" => users} = conn |> get(~p"/rpc/users") |> json_response(200)
      assert Enum.any?(users, &(&1["email"] == "ui@example.com"))

      assert %{"ok" => true} =
               conn |> post(~p"/rpc/auth", %{"enabled" => true}) |> json_response(200)

      assert Longpi.Auth.enabled?()

      # The toggle is LIVE: an unauthenticated request now 401s...
      assert conn |> get(~p"/rpc/version") |> json_response(401)

      # ...so turning it back off needs an authorized session.
      authed = Phoenix.ConnTest.init_test_session(conn, %{embed_authorized: true})

      assert %{"ok" => true} =
               authed |> post(~p"/rpc/auth", %{"enabled" => false}) |> json_response(200)

      refute Longpi.Auth.enabled?()
    end

    test "saving an existing email resets its password", %{conn: conn} do
      conn
      |> post(~p"/rpc/users", %{"email" => "reset@example.com", "password" => "first-pass1"})
      |> json_response(200)

      conn
      |> post(~p"/rpc/users", %{"email" => "reset@example.com", "password" => "second-pass2"})
      |> json_response(200)

      assert {:ok, _user} =
               Longpi.Accounts.User
               |> Ash.Query.for_read(:sign_in_with_password, %{
                 email: "reset@example.com",
                 password: "second-pass2"
               })
               |> Ash.read_one(authorize?: false)
    end

    test "the last account cannot be deleted while sign-in is on", %{conn: conn} do
      %{"id" => id} =
        conn
        |> post(~p"/rpc/users", %{"email" => "only@example.com", "password" => "secret123"})
        |> json_response(200)

      conn |> post(~p"/rpc/auth", %{"enabled" => true}) |> json_response(200)

      authed = Phoenix.ConnTest.init_test_session(conn, %{embed_authorized: true})

      if Ash.count!(Longpi.Accounts.User, authorize?: false) == 1 do
        assert json_response(post(authed, ~p"/rpc/users/delete", %{"id" => id}), 422)["error"] =~
                 "last account"
      end
    end

    test "a too-short password errors cleanly", %{conn: conn} do
      body =
        conn
        |> post(~p"/rpc/users", %{"email" => "short@example.com", "password" => "tiny"})
        |> json_response(422)

      assert body["error"] != nil
    end

    test "the toggle is read-only when config pins auth", %{conn: conn} do
      enable_auth()

      # A pinned config wins and the endpoint refuses to flip it. (The gate is
      # bypassed here via an embed-authorized session, since auth is now on.)
      conn = Phoenix.ConnTest.init_test_session(conn, %{embed_authorized: true})
      assert json_response(post(conn, ~p"/rpc/auth", %{"enabled" => false}), 422)["error"] =~
               "pinned"
    end
  end

  describe "embed token (host-authenticated iframe)" do
    setup do
      Application.put_env(:longpi, :embed_token, "embed-secret-123")
      on_exit(fn -> Application.delete_env(:longpi, :embed_token) end)
      :ok
    end

    test "a valid ?token= opens /embed without a sign-in", %{conn: conn} do
      enable_auth()
      conn = get(conn, ~p"/embed?token=embed-secret-123&cwd=/tmp/x")
      assert html_response(conn, 200)
      # ...and the session is now authorized for the SPA's follow-up fetches.
      assert get_session(conn, :embed_authorized) == true
    end

    test "a wrong token still redirects to sign-in", %{conn: conn} do
      enable_auth()
      conn = get(conn, ~p"/embed?token=wrong&cwd=/tmp/x")
      assert redirected_to(conn) == "/sign-in"
      refute get_session(conn, :embed_authorized)
    end

    test "the RPC gate honors the embed-authorized session", %{conn: conn} do
      enable_auth()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{embed_authorized: true})
        |> get(~p"/rpc/version")

      assert json_response(conn, 200)
    end

    test "the websocket accepts the embed token when auth is on" do
      enable_auth()

      assert {:ok, _socket} =
               LongpiWeb.UserSocket.connect(
                 %{"token" => "embed-secret-123"},
                 %Phoenix.Socket{},
                 %{}
               )

      assert :error =
               LongpiWeb.UserSocket.connect(%{"token" => "nope"}, %Phoenix.Socket{}, %{})
    end
  end

  describe "embed frame headers" do
    test "/embed can be iframed (frame-ancestors relaxed)", %{conn: conn} do
      conn = get(conn, ~p"/embed")
      assert html_response(conn, 200)
      assert get_resp_header(conn, "x-frame-options") == []
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors *"
    end

    test "the normal SPA keeps its frame-ancestors 'self' guard", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self'"
    end
  end

  describe "seeder" do
    test "parses email:password pairs across separators" do
      assert Seeder.parse("a@b.c:pw1, d@e.f:pw2;\ng@h.i:with:colon") == [
               {"a@b.c", "pw1"},
               {"d@e.f", "pw2"},
               {"g@h.i", "with:colon"}
             ]

      assert Seeder.parse("") == []
      assert Seeder.parse("garbage") == []
    end

    test "creates an account and is idempotent without the reset flag" do
      Application.put_env(:longpi, :bootstrap_users, "seed@example.com:secret123")
      on_exit(fn -> Application.delete_env(:longpi, :bootstrap_users) end)

      assert :ok = Seeder.run()
      assert {:ok, user} = fetch_user("seed@example.com")
      first_hash = user.hashed_password

      # Second boot with the same line: no change (bootstrap-only semantics).
      assert :ok = Seeder.run()
      assert {:ok, user2} = fetch_user("seed@example.com")
      assert user2.hashed_password == first_hash
    end

    test "verify_accounts_exist! raises only when auth is on and nobody exists" do
      # Auth off: fine regardless.
      assert :ok = Seeder.verify_accounts_exist!()

      enable_auth()

      if match?({:ok, 0}, Ash.count(Longpi.Accounts.User, authorize?: false)) do
        assert_raise RuntimeError, ~r/no user accounts exist/, fn ->
          Seeder.verify_accounts_exist!()
        end
      end
    end
  end

  defp fetch_user(email) do
    Longpi.Accounts.User
    |> Ash.Query.for_read(:get_by_email, %{email: email})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Longpi.Accounts.User{} = user} -> {:ok, user}
      other -> other
    end
  end
end
