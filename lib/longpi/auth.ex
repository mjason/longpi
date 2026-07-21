defmodule Longpi.Auth do
  @moduledoc """
  Optional username/password protection for the whole app (dala's model).

  Off by default — a fresh install stays a zero-config LAN tool. Turned on via
  `LONGPI_AUTH_ENABLED=true` (any env) or `"auth": {"enabled": true}` in
  config.jsonc (prod). When on:

    * every SPA page and `/rpc/*` route requires a signed-in user
      (`LongpiWeb.Plugs.RequireAuth`);
    * the websocket requires a bearer token (`LongpiWeb.UserSocket`);
    * accounts come from the boot seeder (`Longpi.Accounts.Seeder`), not
      self-registration.
  """

  alias Longpi.Accounts.User

  def enabled?, do: Application.get_env(:longpi, :auth_enabled, false)

  @doc """
  The signed-in session's bearer token for the websocket.

  ash_authentication stores the session JWT under `"user_token"`
  (`<subject_name>_token`, because `require_token_presence_for_authentication?`
  is on). Handing that same stored, revocable token to the socket means socket
  access dies with the session. NOTE: it is NOT in `user.__metadata__.token` on
  session-loaded requests — that is only set during the sign-in request itself.
  """
  def bearer_token(%Plug.Conn{} = conn) do
    case Plug.Conn.get_session(conn, "user_token") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc "Verifies a websocket bearer token. `{:ok, user}` or `:error`."
  def verify_bearer_token(token) when is_binary(token) and token != "" do
    with {:ok, claims, _resource} <- AshAuthentication.Jwt.verify(token, :longpi),
         # Only session tokens open a socket — not e.g. the short-lived
         # purpose: "sign_in" exchange token.
         true <- claims["purpose"] in [nil, "user"],
         {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], User) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def verify_bearer_token(_token), do: :error

  @doc """
  The embed token — a static secret a HOST app (e.g. dala) appends to its
  iframe URL (`/embed?token=...`) so the embedded agent works without a browser
  sign-in. Auto-generated into `<data_dir>/secrets.json` ("embedToken") on
  first prod boot; overridable via config.jsonc `auth.embedToken` or
  `LONGPI_EMBED_TOKEN`. Treat it like a password.
  """
  def embed_token do
    case Application.get_env(:longpi, :embed_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc "Constant-time check of a presented embed token."
  def verify_embed_token(presented) when is_binary(presented) and presented != "" do
    case embed_token() do
      nil -> false
      token -> Plug.Crypto.secure_compare(presented, token)
    end
  end

  def verify_embed_token(_presented), do: false
end
