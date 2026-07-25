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

  # Surfaces an embed-token session must NOT reach: the token authorizes
  # driving a conversation from a host iframe, not administering the install.
  # Without this, any page that can read the iframe URL holds full admin
  # (user management, auth toggle, self-upgrade, secrets, the token itself).
  @admin_prefixes ["/manage", "/rpc/users", "/rpc/auth", "/rpc/version/upgrade",
                   "/rpc/embed-info", "/rpc/extensions/secrets"]

  def init(opts), do: opts

  def call(conn, opts) do
    cond do
      not Longpi.Auth.enabled?() || conn.assigns[:current_user] ->
        conn

      get_session(conn, :embed_authorized) ->
        if admin_path?(conn.request_path) do
          conn
          |> put_status(:forbidden)
          |> json(%{error: "embed sessions cannot access management endpoints"})
          |> halt()
        else
          conn
        end

      true ->
        deny(conn, opts)
    end
  end

  defp admin_path?(path), do: Enum.any?(@admin_prefixes, &String.starts_with?(path, &1))

  defp deny(conn, opts) do
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
