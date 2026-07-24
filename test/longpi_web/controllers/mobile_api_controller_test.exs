defmodule LongpiWeb.MobileApiControllerTest do
  # The native shell's JSON API: list/create/delete conversations + models,
  # authorized per-request by the embed token (open when sign-in is off).
  use LongpiWeb.ConnCase

  describe "auth flow (status probe + native login)" do
    setup do
      Application.delete_env(:longpi, :auth_enabled)
      on_exit(fn -> Application.delete_env(:longpi, :auth_enabled) end)
      :ok
    end

    test "status: auth off means straight in", %{conn: conn} do
      Application.put_env(:longpi, :auth_enabled, false)
      conn = get(conn, ~p"/api/mobile/status")
      assert %{"auth_enabled" => false, "authorized" => true} = json_response(conn, 200)
    end

    test "status: auth on requires a valid token", %{conn: conn} do
      Application.put_env(:longpi, :auth_enabled, true)
      Application.put_env(:longpi, :embed_token, "tok-123")
      on_exit(fn -> Application.delete_env(:longpi, :embed_token) end)

      assert %{"auth_enabled" => true, "authorized" => false} =
               conn |> get(~p"/api/mobile/status") |> json_response(200)

      assert %{"authorized" => true} =
               conn |> get(~p"/api/mobile/status?token=tok-123") |> json_response(200)
    end

    test "login exchanges email+password for the embed token", %{conn: conn} do
      Application.put_env(:longpi, :auth_enabled, true)
      Application.put_env(:longpi, :embed_token, "tok-456")
      Application.put_env(:longpi, :bootstrap_users, "phone@example.com:secret123")

      on_exit(fn ->
        Application.delete_env(:longpi, :embed_token)
        Application.delete_env(:longpi, :bootstrap_users)
      end)

      :ok = Longpi.Accounts.Seeder.run()

      assert %{"token" => "tok-456", "auth_enabled" => true} =
               conn
               |> post(~p"/api/mobile/login", %{
                 "email" => "phone@example.com",
                 "password" => "secret123"
               })
               |> json_response(200)

      assert %{"error" => error} =
               conn
               |> post(~p"/api/mobile/login", %{
                 "email" => "phone@example.com",
                 "password" => "wrong"
               })
               |> json_response(401)

      assert error =~ "invalid"
    end

    test "the token-guarded API rejects a bad token when auth is on", %{conn: conn} do
      Application.put_env(:longpi, :auth_enabled, true)
      Application.put_env(:longpi, :embed_token, "tok-789")
      on_exit(fn -> Application.delete_env(:longpi, :embed_token) end)

      assert json_response(get(conn, ~p"/api/mobile/conversations"), 401)
      assert json_response(get(conn, ~p"/api/mobile/conversations?token=nope"), 401)
      assert json_response(get(conn, ~p"/api/mobile/conversations?token=tok-789"), 200)
    end
  end

  test "lists top-level conversations newest-first (subagents excluded)", %{conn: conn} do
    parent = Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

    Longpi.Agent.create_conversation!(%{
      cwd: System.tmp_dir!(),
      model: "test:model",
      parent_id: parent.id,
      agent_role: "scout"
    })

    conn = get(conn, ~p"/api/mobile/conversations")
    assert %{"conversations" => [only]} = json_response(conn, 200)
    assert only["id"] == parent.id
    assert only["cwd"] == System.tmp_dir!()
  end

  test "creates a conversation with the default model and deletes it", %{conn: conn} do
    conn1 = post(conn, ~p"/api/mobile/conversations", %{"cwd" => System.tmp_dir!()})
    assert %{"id" => id, "model" => model} = json_response(conn1, 200)
    assert is_binary(model) and model != ""

    conn2 = delete(conn, ~p"/api/mobile/conversations/#{id}")
    assert %{"ok" => true} = json_response(conn2, 200)

    conn3 = delete(conn, ~p"/api/mobile/conversations/#{id}")
    assert json_response(conn3, 404)
  end

  test "missing cwd is a 422", %{conn: conn} do
    conn = post(conn, ~p"/api/mobile/conversations", %{})
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "cwd"
  end

  test "lists enabled models with the default", %{conn: conn} do
    Longpi.Agent.create_model!(%{spec: "openai:list-me", enabled: true})
    Longpi.Agent.create_model!(%{spec: "openai:hidden", enabled: false})

    conn = get(conn, ~p"/api/mobile/models")
    assert %{"models" => models, "default" => default} = json_response(conn, 200)
    assert Enum.any?(models, &(&1["spec"] == "openai:list-me"))
    refute Enum.any?(models, &(&1["spec"] == "openai:hidden"))
    assert is_binary(default)
  end
end
