defmodule LongpiWeb.PageController do
  use LongpiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def index conn, _params do
    conn |> put_root_layout(html: {LongpiWeb.Layouts, :spa_root}) |> render(:index)
  end
end
