defmodule LongpiWeb.PageController do
  use LongpiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    conn
    |> put_root_layout(html: {LongpiWeb.Layouts, :spa_root})
    # Surfaced as meta tags so the SPA knows who is signed in and can hand the
    # (revocable) session token to the websocket.
    |> assign(:user_email, user && to_string(user.email))
    |> assign(:socket_token, user && Longpi.Auth.bearer_token(conn))
    |> render(:index)
  end
end
