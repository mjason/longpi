defmodule Longpi.Workspace.Git do
  @moduledoc """
  Git operations for the workspace sidebar, backed by libgit2 through the
  precompiled `Git2Ex` NIF (our own package, github.com/mjason/git2ex) —
  no cargo build for consumers, no `git` CLI dependency.

  Every function takes the conversation's cwd; the repository root is
  discovered by libgit2. Output-bearing results are size-capped in the NIF
  so a pathological diff can't flood the browser. This module keeps the
  wire-facing shapes stable: status codes are TRIMMED (`"M"`, `"??"`,
  `"MM"`), log dates are ISO8601 strings.
  """

  alias Git2Ex, as: GitNif

  @file_cap 2_000_000

  @doc """
  Working-tree status: `%{repo, root, branch, files: [%{path, status,
  staged, unstaged}]}`. `repo: false` when cwd is not inside a repository.
  """
  def status(cwd) do
    case GitNif.status(cwd) do
      {:ok, result} ->
        {:ok, %{result | files: Enum.map(result.files, &%{&1 | status: String.trim(&1.status)})}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Unified diff for one file. `staged?` picks HEAD↔index, else index↔worktree."
  def diff(cwd, file, staged?), do: GitNif.diff_file(cwd, file, staged?)

  @doc """
  A file's full content at a revision — `"WORKTREE"`, `":0"` (index),
  `"HEAD"`, or a commit-ish. Feeds the side-by-side diff viewer.
  """
  def file_at(cwd, "WORKTREE", file) do
    with {:ok, %{root: root}} when is_binary(root) <- worktree_root(cwd) do
      case File.read(Path.join(root, file)) do
        {:ok, bytes} -> {:ok, worktree_payload(bytes)}
        {:error, :enoent} -> {:ok, %{content: "", binary: false, truncated: false, missing: true}}
        {:error, reason} -> {:error, "cannot read #{file}: #{inspect(reason)}"}
      end
    end
  end

  def file_at(cwd, rev, file) do
    with :ok <- validate_rev(rev), do: GitNif.file_at(cwd, rev, file)
  end

  def stage(cwd, file), do: to_ok(GitNif.stage(cwd, file))
  def unstage(cwd, file), do: to_ok(GitNif.unstage(cwd, file))

  @doc "Throw away a file's working-tree changes (untracked files are deleted)."
  def discard(cwd, file), do: to_ok(GitNif.discard(cwd, file))

  def commit(cwd, message, amend?) when is_binary(message) do
    if amend?, do: GitNif.commit_amend(cwd, message), else: GitNif.commit(cwd, message)
  end

  def log(cwd, limit) when is_integer(limit) do
    with {:ok, commits} <- GitNif.log(cwd, min(max(limit, 1), 200)) do
      {:ok,
       Enum.map(commits, fn c ->
         %{hash: c.hash, author: c.author, subject: c.subject, date: iso8601(c.date_unix)}
       end)}
    end
  end

  def show(cwd, hash) do
    with :ok <- validate_hash(hash), do: GitNif.show(cwd, hash)
  end

  # ── Internals ─────────────────────────────────────────────────────────

  # Cheap root lookup (walks up for the repo) — NOT a full status walk, which
  # is all reading a worktree file by path needs.
  defp worktree_root(cwd) do
    case GitNif.discover(cwd) do
      {:ok, %{repo: true, root: root}} when is_binary(root) -> {:ok, %{root: root}}
      {:ok, _} -> {:error, "not a git repository"}
      {:error, _} = error -> error
    end
  end

  defp to_ok({:ok, _}), do: :ok
  defp to_ok({:error, _} = error), do: error

  defp iso8601(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> ""
    end
  end

  defp validate_hash(hash) do
    if is_binary(hash) and hash =~ ~r/^[0-9a-fA-F]{4,64}$/,
      do: :ok,
      else: {:error, "invalid commit hash"}
  end

  # Belt-and-braces: libgit2 revparse never shells out, but the diff viewer
  # only ever sends these shapes — reject anything else at the boundary.
  defp validate_rev(rev) do
    if is_binary(rev) and rev =~ ~r/^[A-Za-z0-9_.~^\/:-]{1,64}$/ and
         not String.starts_with?(rev, "-"),
       do: :ok,
       else: {:error, "invalid revision"}
  end

  defp worktree_payload(bytes) do
    binary? = String.contains?(bytes, <<0>>)
    {content, truncated} =
      if byte_size(bytes) > @file_cap,
        do: {String.replace_invalid(binary_part(bytes, 0, @file_cap)), true},
        else: {bytes, false}

    %{
      content: if(binary?, do: "", else: String.replace_invalid(content)),
      binary: binary?,
      truncated: truncated,
      missing: false
    }
  end
end
