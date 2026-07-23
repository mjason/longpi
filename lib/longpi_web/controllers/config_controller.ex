defmodule LongpiWeb.ConfigController do
  @moduledoc """
  Read-only config the admin UI needs but that isn't a plain resource: the
  built-in tool catalog and the default system prompt (so the editor can show
  the real default instead of an empty box).
  """

  use LongpiWeb, :controller

  # A fresh CSRF token for the current session. The SPA calls this to self-heal
  # a stale `<meta>` token (open tab across a deploy / cached index) and retry a
  # POST that got 403'd, instead of forcing a hard reload.
  def csrf(conn, _params) do
    json(conn, %{token: Plug.CSRFProtection.get_csrf_token()})
  end

  def tool_catalog(conn, _params) do
    json(conn, %{tools: Longpi.Agent.Prompts.tool_catalog()})
  end

  # Next run times for a batch of cron expressions (the Schedules admin page
  # shows them; cron math lives server-side with the scheduler's clock).
  # Capped and type-filtered: next_run searches up to 10k candidate dates per
  # expression, so an unbounded hostile list would pin the CPU — and non-string
  # entries would crash the parser.
  def cron_next(conn, %{"crons" => crons}) when is_list(crons) do
    nexts =
      crons
      |> Enum.filter(&is_binary/1)
      |> Enum.take(100)
      |> Map.new(fn cron ->
        case Longpi.Agent.Scheduler.next_run(cron) do
          {:ok, at} -> {cron, NaiveDateTime.to_string(at)}
          :error -> {cron, nil}
        end
      end)

    json(conn, %{nexts: nexts})
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
      extensions: Longpi.Extensions.list_global()
    })
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

  # Workspace file list for the composer's "@" file mentions. Returns paths
  # relative to cwd (fd's engine; respects .gitignore).
  def list_files(conn, %{"cwd" => cwd} = params) when is_binary(cwd) do
    query = params["q"] || ""
    # A bare substring query becomes a glob; glob metacharacters are stripped
    # so untrusted input can't turn into a pathological pattern.
    sanitized = String.replace(query, ~r/[*?\[\]{}]/, "")
    pattern = if sanitized == "", do: "**/*", else: "**/*#{sanitized}*"

    case Longpi.Search.find(%{pattern: pattern, limit: 300}, cwd: cwd) do
      {:ok, %{"files" => files}} -> json(conn, %{files: files})
      _ -> json(conn, %{files: []})
    end
  end

  # File preview for local paths linked in chat messages: text files return
  # their (capped) content, images/binaries return just metadata so the client
  # can render via /rpc/file/raw or offer a download.
  @preview_cap 256_000

  def file_preview(conn, %{"path" => path} = params) when is_binary(path) do
    case resolve_file(path, params["cwd"]) do
      {:ok, abs, %File.Stat{size: size}} ->
        mime = MIME.from_path(abs)
        base = %{name: Path.basename(abs), path: abs, size: size, mime: mime}

        cond do
          String.starts_with?(mime, "image/") ->
            json(conn, Map.put(base, :kind, "image"))

          true ->
            {head, truncated} = read_head(abs, size)

            case printable_text(head) do
              {:ok, text} ->
                json(
                  conn,
                  base |> Map.merge(%{kind: "text", content: text, truncated: truncated})
                )

              :binary ->
                json(conn, Map.put(base, :kind, "binary"))
            end
        end

      :error ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  def file_raw(conn, %{"path" => path} = params) when is_binary(path) do
    case resolve_file(path, params["cwd"]) do
      {:ok, abs, _stat} ->
        disposition = if params["download"] in ["1", "true"], do: "attachment", else: "inline"
        encoded_name = URI.encode(Path.basename(abs), &URI.char_unreserved?/1)

        conn
        |> put_resp_content_type(MIME.from_path(abs), nil)
        |> put_resp_header(
          "content-disposition",
          "#{disposition}; filename*=UTF-8''#{encoded_name}"
        )
        |> send_file(200, abs)

      :error ->
        send_resp(conn, 404, "not found")
    end
  end

  # Absolute paths (and file:// / ~) are taken as-is; relative paths resolve
  # against the conversation's cwd. An absolute-looking path that doesn't
  # exist also falls back to cwd-relative: the client's markdown sanitizer
  # resolves relative hrefs against the page origin, so `lib/foo.ex` arrives
  # here as `/lib/foo.ex`. Only regular files qualify.
  defp resolve_file(path, cwd) do
    candidates =
      cond do
        String.starts_with?(path, "file://") ->
          [String.replace_prefix(path, "file://", "")]

        String.starts_with?(path, "~") ->
          [Path.expand(path)]

        Path.type(path) == :absolute ->
          [path | cwd_candidate(String.trim_leading(path, "/"), cwd)]

        true ->
          cwd_candidate(path, cwd) ++ [Path.expand(path)]
      end

    Enum.find_value(candidates, :error, fn abs ->
      case File.stat(abs) do
        {:ok, %File.Stat{type: :regular} = stat} -> {:ok, abs, stat}
        _ -> nil
      end
    end)
  end

  defp cwd_candidate(rel, cwd) when is_binary(cwd) and cwd != "", do: [Path.expand(rel, cwd)]
  defp cwd_candidate(_rel, _cwd), do: []

  defp read_head(path, size) do
    if size > @preview_cap do
      {:ok, io} = File.open(path, [:read, :binary])
      head = IO.binread(io, @preview_cap)
      File.close(io)
      {head, true}
    else
      {File.read!(path), false}
    end
  end

  # Text iff valid UTF-8 with no NUL bytes. A truncated read may split a
  # multi-byte character, so trim up to 3 trailing bytes before giving up.
  defp printable_text(bytes) do
    if String.contains?(bytes, <<0>>) do
      :binary
    else
      trim_to_valid(bytes, 3)
    end
  end

  defp trim_to_valid(bytes, tries) do
    cond do
      String.valid?(bytes) -> {:ok, bytes}
      tries == 0 or byte_size(bytes) == 0 -> :binary
      true -> trim_to_valid(binary_part(bytes, 0, byte_size(bytes) - 1), tries - 1)
    end
  end

  # Fork: a NEW conversation seeded with this one's history up to (and
  # including) `position` — "start a new conversation from here".
  # position >= 0 copies rows 0..position; -1 copies nothing (forking BEFORE
  # the first message: fresh history, the client prefills the composer).
  def fork_conversation(conn, %{"conversation_id" => id, "position" => position})
      when is_integer(position) and position >= -1 do
    with {:ok, source} <- Longpi.Agent.get_conversation(id) do
      {:ok, fork} =
        Longpi.Agent.create_conversation(%{
          cwd: source.cwd,
          model: source.model,
          system_prompt: source.system_prompt,
          reasoning_effort: source.reasoning_effort,
          title: fork_title(source)
        })

      id
      |> Longpi.Agent.list_messages!()
      |> Enum.filter(&(&1.position <= position))
      |> Enum.each(fn message ->
        Longpi.Agent.append_message!(%{
          role: message.role,
          content: message.content,
          attachments: message.attachments,
          tool_calls: message.tool_calls,
          tool_call_id: message.tool_call_id,
          tool_name: message.tool_name,
          error: message.error,
          position: message.position,
          conversation_id: fork.id
        })
      end)

      json(conn, %{id: fork.id, cwd: fork.cwd, model: fork.model, title: fork.title})
    else
      _ -> conn |> put_status(404) |> json(%{error: "conversation not found"})
    end
  end

  defp fork_title(%{title: nil}), do: nil
  defp fork_title(%{title: title}), do: "#{title} ⑂"

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
