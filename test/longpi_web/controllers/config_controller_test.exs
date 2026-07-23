defmodule LongpiWeb.ConfigControllerTest do
  use LongpiWeb.ConnCase

  test "GET /rpc/csrf returns a fresh CSRF token", %{conn: conn} do
    conn = get(conn, ~p"/rpc/csrf")
    assert %{"token" => token} = json_response(conn, 200)
    assert is_binary(token) and token != ""
  end
end
