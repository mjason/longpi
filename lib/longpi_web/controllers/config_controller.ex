defmodule LongpiWeb.ConfigController do
  @moduledoc """
  Read-only config the admin UI needs but that isn't a plain resource: the
  built-in tool catalog and the default system prompt (so the editor can show
  the real default instead of an empty box).
  """

  use LongpiWeb, :controller

  def tool_catalog(conn, _params) do
    json(conn, %{tools: Longpi.Agent.Prompts.tool_catalog()})
  end

  def defaults(conn, _params) do
    json(conn, %{
      system_prompt: Longpi.Agent.SystemPrompt.default_template(),
      tools: Longpi.Agent.Prompts.tool_catalog()
    })
  end

  def discover_models(conn, %{"provider" => provider}) do
    case Longpi.Agent.ModelDiscovery.list(provider) do
      {:ok, models} -> json(conn, %{models: models})
      {:error, message} -> conn |> put_status(422) |> json(%{error: message})
    end
  end

  def sessions(conn, _params) do
    json(conn, %{sessions: Longpi.Agent.Sessions.list_active()})
  end

  def stop_session(conn, %{"conversation_id" => id}) do
    Longpi.Agent.Sessions.stop(id)
    json(conn, %{ok: true})
  end

  def extensions(conn, _params) do
    json(conn, %{
      dir: Longpi.Extensions.global_dir(),
      extensions: Longpi.Extensions.list_global(),
      packages: Longpi.Extensions.read_packages()
    })
  end

  def save_packages(conn, %{"packages" => packages}) when is_map(packages) do
    case Longpi.Extensions.write_packages(packages) do
      :ok -> json(conn, %{ok: true})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # Extension secrets: names only leave the server; values are write-only.
  def extension_secrets(conn, _params) do
    json(conn, %{names: Longpi.Extensions.list_secret_names()})
  end

  def save_extension_secret(conn, %{"name" => name, "value" => value})
      when is_binary(name) and is_binary(value) do
    name = String.trim(name)

    cond do
      name == "" ->
        conn |> put_status(422) |> json(%{error: "name is required"})

      not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name) ->
        conn
        |> put_status(422)
        |> json(%{error: "name must be a valid environment variable name (A-Z, 0-9, _)"})

      true ->
        case Longpi.Extensions.put_secret(name, value) do
          :ok -> json(conn, %{ok: true})
          {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
  end

  def delete_extension_secret(conn, %{"name" => name}) when is_binary(name) do
    Longpi.Extensions.delete_secret(name)
    json(conn, %{ok: true})
  end

  # ── Users & sign-in (Management → Users) ─────────────────────────────────
  # Account management lives HERE, in the UI — passwords go straight to the
  # database and never through config files or shell history.

  def auth_status(conn, _params) do
    json(conn, %{
      enabled: Longpi.Auth.enabled?(),
      forced: Longpi.Auth.forced?(),
      userCount: Ash.count!(Longpi.Accounts.User, authorize?: false)
    })
  end

  def set_auth(conn, %{"enabled" => enabled}) when is_boolean(enabled) do
    cond do
      Longpi.Auth.forced?() ->
        conn
        |> put_status(422)
        |> json(%{error: "auth is pinned by config.jsonc / LONGPI_AUTH_ENABLED"})

      enabled and Ash.count!(Longpi.Accounts.User, authorize?: false) == 0 ->
        conn |> put_status(422) |> json(%{error: "add a user first"})

      true ->
        :ok = Longpi.Auth.set_enabled(enabled)
        json(conn, %{ok: true, enabled: enabled})
    end
  end

  def list_users(conn, _params) do
    users =
      Longpi.Accounts.User
      |> Ash.read!(authorize?: false)
      |> Enum.sort_by(& &1.email)
      |> Enum.map(&%{id: &1.id, email: to_string(&1.email)})

    json(conn, %{users: users})
  end

  # Create AND reset share the seed_user upsert: same email = new password.
  def put_user(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Longpi.Accounts.User
         |> Ash.Changeset.for_create(:seed_user, %{email: String.trim(email), password: password})
         |> Ash.create(authorize?: false) do
      {:ok, user} ->
        json(conn, %{ok: true, id: user.id, email: to_string(user.email)})

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: Exception.message(error)})
    end
  end

  def delete_user(conn, %{"id" => id}) when is_binary(id) do
    last? = Ash.count!(Longpi.Accounts.User, authorize?: false) <= 1

    cond do
      last? and Longpi.Auth.enabled?() ->
        conn
        |> put_status(422)
        |> json(%{error: "cannot delete the last account while sign-in is on"})

      true ->
        with {:ok, user} <- Ash.get(Longpi.Accounts.User, id, authorize?: false),
             :ok <- Ash.destroy(user, authorize?: false) do
          json(conn, %{ok: true})
        else
          _ -> conn |> put_status(422) |> json(%{error: "could not delete the account"})
        end
    end
  end

  # Embed integration info for the management UI: whether auth is on, the
  # embed token (this endpoint sits behind the auth gate, so with auth enabled
  # only a signed-in user can read it), and the base URL for iframe snippets.
  def embed_info(conn, _params) do
    json(conn, %{
      authEnabled: Longpi.Auth.enabled?(),
      embedToken: Longpi.Auth.embed_token(),
      baseUrl: LongpiWeb.Endpoint.url()
    })
  end

  # Self-update: check GitHub for a newer release, and apply it on demand.
  def version(conn, _params) do
    case Longpi.Updater.check() do
      {:ok, info} ->
        json(conn, %{
          enabled: info.enabled,
          current: info.current,
          latest: info.latest,
          tag: info.tag,
          updateAvailable: info.update_available,
          notesUrl: info.notes_url
        })

      {:error, reason} ->
        # A GitHub hiccup shouldn't error the UI; report what we know locally.
        json(conn, %{
          enabled: Longpi.Updater.enabled?(),
          current: Longpi.Updater.current_version(),
          latest: nil,
          tag: nil,
          updateAvailable: false,
          notesUrl: nil,
          error: to_string(reason)
        })
    end
  end

  def upgrade(conn, _params) do
    case Longpi.Updater.apply_latest() do
      {:ok, %{updated_to: tag}} -> json(conn, %{ok: true, updatedTo: tag})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end
end
