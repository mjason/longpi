defmodule LongpiWeb.WorkspaceController do
  @moduledoc """
  The workspace sidebar's data plane: directory listings for the file tree
  and git operations for the git panel (dala's feature set over plain JSON
  endpoints — longpi's convention for tool endpoints).

  Trust model matches dala's: no path sandbox beyond app auth, because the
  agent's own bash tool can already touch anything the server user can.
  """

  use LongpiWeb, :controller

  alias Longpi.Workspace.Git

  # ── File tree ─────────────────────────────────────────────────────────

  @doc """
  One directory level for the lazy tree. Directories first, case-insensitive;
  hidden-file filtering is the CLIENT's job (dala's split) so the toggle
  doesn't refetch.
  """
  def list_dir(conn, %{"path" => path}) when is_binary(path) do
    expanded = Path.expand(path)

    case File.ls(expanded) do
      {:ok, names} ->
        entries =
          names
          |> Enum.map(&entry(expanded, &1))
          |> Enum.sort_by(fn e -> {e.type != "directory", String.downcase(e.name)} end)

        parent = if expanded == "/", do: nil, else: Path.dirname(expanded)
        json(conn, %{path: expanded, parent: parent, entries: entries})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: "cannot list #{expanded}: #{reason}"})
    end
  end

  defp entry(dir, name) do
    full = Path.join(dir, name)
    lstat = File.lstat(full)
    stat = File.stat(full, time: :posix)

    type =
      case stat do
        {:ok, %{type: :directory}} -> "directory"
        {:ok, %{type: :regular}} -> "file"
        _ -> "other"
      end

    %{
      name: name,
      type: type,
      symlink: match?({:ok, %{type: :symlink}}, lstat),
      size: (match?({:ok, _}, stat) && elem(stat, 1).size) || 0
    }
  end

  # ── Git ───────────────────────────────────────────────────────────────

  def git_status(conn, %{"cwd" => cwd}) when is_binary(cwd) do
    {:ok, status} = Git.status(cwd)
    json(conn, status)
  end

  def git_diff(conn, %{"cwd" => cwd, "file" => file} = params)
      when is_binary(cwd) and is_binary(file) do
    respond(conn, Git.diff(cwd, file, params["staged"] in ["1", "true", true]))
  end

  def git_file_at(conn, %{"cwd" => cwd, "rev" => rev, "file" => file})
      when is_binary(cwd) and is_binary(rev) and is_binary(file) do
    respond(conn, Git.file_at(cwd, rev, file))
  end

  def git_stage(conn, %{"cwd" => cwd, "file" => file}), do: respond_ok(conn, Git.stage(cwd, file))

  def git_unstage(conn, %{"cwd" => cwd, "file" => file}),
    do: respond_ok(conn, Git.unstage(cwd, file))

  def git_discard(conn, %{"cwd" => cwd, "file" => file}),
    do: respond_ok(conn, Git.discard(cwd, file))

  def git_commit(conn, %{"cwd" => cwd, "message" => message} = params)
      when is_binary(cwd) and is_binary(message) do
    if String.trim(message) == "" do
      conn |> put_status(422) |> json(%{error: "commit message is required"})
    else
      case Git.commit(cwd, message, params["amend"] in [true, "true", "1"]) do
        {:ok, hash} -> json(conn, %{hash: hash})
        {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
      end
    end
  end

  def git_log(conn, %{"cwd" => cwd} = params) when is_binary(cwd) do
    limit =
      case Integer.parse(to_string(params["limit"] || "50")) do
        {n, _} -> n
        :error -> 50
      end

    case Git.log(cwd, limit) do
      {:ok, commits} -> json(conn, %{commits: commits})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def git_show(conn, %{"cwd" => cwd, "hash" => hash})
      when is_binary(cwd) and is_binary(hash) do
    respond(conn, Git.show(cwd, hash))
  end

  defp respond(conn, {:ok, payload}), do: json(conn, payload)
  defp respond(conn, {:error, reason}), do: conn |> put_status(422) |> json(%{error: reason})

  defp respond_ok(conn, :ok), do: json(conn, %{ok: true})
  defp respond_ok(conn, {:error, reason}), do: conn |> put_status(422) |> json(%{error: reason})
end
