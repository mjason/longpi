defmodule LongpiWeb.PageControllerTest do
  use LongpiWeb.ConnCase

  test "GET / serves the chat SPA", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ ~s(id="app")
    assert response =~ "Longpi"
  end
end
