defmodule LongpiWeb.MobileApiController do
  @moduledoc """
  JSON API for the native mobile shell (SwiftUI list + WKWebView chat pages).

  The shell renders the conversation LIST natively — that's where native
  navigation pays off — and opens `/m/c/:id?token=` in a WebView per chat.
  Auth is the embed token on every request (router `:mobile_token_auth`).
  """

  use LongpiWeb, :controller

  @doc """
  Boot probe for the shell: does this server require login, and does the
  presented token (if any) already authorize us? Drives the app's flow —
  `auth_enabled: false` → straight in; `authorized: false` → show login.
  """
  def status(conn, params) do
    enabled = Longpi.Auth.enabled?()

    json(conn, %{
      auth_enabled: enabled,
      authorized: not enabled or Longpi.Auth.verify_embed_token(params["token"])
    })
  end

  @doc """
  Native login: email + password → the embed token. The app shows a normal
  sign-in form and stores the returned token in the Keychain — token stays the
  transport credential (no WKWebView/URLSession cookie syncing), the password
  is only ever used here.
  """
  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    cond do
      not Longpi.Auth.enabled?() ->
        json(conn, %{token: nil, auth_enabled: false})

      not LongpiWeb.LoginThrottle.allowed?(client_ip(conn)) ->
        conn |> put_status(429) |> json(%{error: "too many attempts — try again later"})

      true ->
      query =
        Longpi.Accounts.User
        |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password})

      case Ash.read_one(query, authorize?: false) do
        {:ok, %Longpi.Accounts.User{}} ->
          case Longpi.Auth.embed_token() do
            token when is_binary(token) and token != "" ->
              LongpiWeb.LoginThrottle.reset(client_ip(conn))
              json(conn, %{token: token, auth_enabled: true})

            _ ->
              # Signed in fine, but there is no token to hand out — a null
              # token would strand the app in a login-succeeds-nothing-works
              # loop. Be explicit.
              conn
              |> put_status(503)
              |> json(%{error: "embed token not configured on the server (set auth.embedToken)"})
          end

        _ ->
          LongpiWeb.LoginThrottle.record_failure(client_ip(conn))
          conn |> put_status(401) |> json(%{error: "invalid email or password"})
      end
    end
  end

  def login(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "email and password are required"})

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  def conversations(conn, _params) do
    conversations =
      Longpi.Agent.list_conversations!()
      |> Enum.reject(& &1.parent_id)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.map(fn c ->
        %{
          id: c.id,
          title: c.title,
          cwd: c.cwd,
          model: c.model,
          updated_at: c.updated_at
        }
      end)

    json(conn, %{conversations: conversations})
  end

  def create_conversation(conn, %{"cwd" => cwd} = params) when is_binary(cwd) do
    attrs = %{
      cwd: String.trim(cwd),
      model: params["model"] || default_model()
    }

    case Longpi.Agent.create_conversation(attrs) do
      {:ok, c} ->
        json(conn, %{id: c.id, title: c.title, cwd: c.cwd, model: c.model})

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: Exception.message(error)})
    end
  end

  def create_conversation(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "cwd is required"})

  def delete_conversation(conn, %{"id" => id}) do
    case Longpi.Agent.get_conversation(id) do
      {:ok, conversation} ->
        Longpi.Agent.destroy_conversation!(conversation)
        json(conn, %{ok: true})

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def models(conn, _params) do
    models =
      Longpi.Agent.list_enabled_models!()
      |> Enum.map(&%{spec: &1.spec, label: &1.label})

    json(conn, %{models: models, default: default_model()})
  end

  defp default_model do
    case Longpi.Agent.get_setting_by_key("default_model") do
      {:ok, %{value: value}} when is_binary(value) and value != "" -> value
      _ -> "openai:gpt-5.4"
    end
  end
end
