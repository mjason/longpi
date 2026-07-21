defmodule LongpiWeb.AuthGateTest do
  # Flips the global auth flag, so never async.
  use LongpiWeb.ConnCase, async: false

  alias Longpi.Accounts.Seeder

  setup do
    on_exit(fn -> Application.delete_env(:longpi, :auth_enabled) end)
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
