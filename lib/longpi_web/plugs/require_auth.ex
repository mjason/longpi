defmodule LongpiWeb.Plugs.RequireAuth do
  @moduledoc """
  Gates a pipeline behind sign-in — a no-op while `Longpi.Auth.enabled?()` is
  false, so the default zero-config install is unaffected.

  Modes:
    * `:page` (default) — remembers where the browser was headed and redirects
      to `/sign-in`.
    * `:api` — replies `401` JSON (the SPA's fetch calls surface the error).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, json: 2, current_path: 1]

  def init(opts), do: opts

  def call(conn, opts) do
    if not Longpi.Auth.enabled?() || conn.assigns[:current_user] ||
         get_session(conn, :embed_authorized) do
      conn
    else
      case Keyword.get(opts, :mode, :page) do
        :api ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "authentication required"})
          |> halt()

        :page ->
          conn
          |> put_session(:return_to, current_path(conn))
          |> redirect(to: "/sign-in")
          |> halt()
      end
    end
  end
end
