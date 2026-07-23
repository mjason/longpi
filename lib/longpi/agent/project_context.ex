defmodule Longpi.Agent.ProjectContext do
  @moduledoc """
  Loads project instruction files (`AGENTS.md` / `CLAUDE.md`) so repo- and
  directory-specific guidance reaches the model — pi's `project_context`.

  Files are collected from a global directory and from every ancestor of the
  workspace, outermost first so the workspace's own file (the most specific)
  reads last. Deduped by absolute path; each read is capped so a large file
  can't flood the prompt. Re-read on each prompt assembly, so edits take effect
  on the next turn.
  """

  @candidates ["AGENTS.md", "CLAUDE.md"]
  @max_bytes 64_000

  @doc "Project instruction files in effect for `cwd`, as `[%{path, content}]`."
  @spec load(String.t()) :: [%{path: String.t(), content: String.t()}]
  def load(cwd) do
    if Application.get_env(:longpi, :project_context_enabled, true) do
      (global_files() ++ ancestor_files(cwd))
      |> Enum.uniq()
      |> Enum.flat_map(&read/1)
    else
      []
    end
  end

  defp global_dir, do: Application.get_env(:longpi, :global_dir, Path.expand("~/.longpi"))

  defp global_files, do: Enum.map(@candidates, &Path.join(global_dir(), &1))

  defp ancestor_files(cwd) do
    cwd
    |> Path.expand()
    |> ancestors()
    |> Enum.flat_map(fn dir -> Enum.map(@candidates, &Path.join(dir, &1)) end)
  end

  # Filesystem root down to `dir` (outermost first).
  defp ancestors(dir) do
    dir
    |> Stream.unfold(fn
      nil -> nil
      current -> {current, if(Path.dirname(current) == current, do: nil, else: Path.dirname(current))}
    end)
    |> Enum.reverse()
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        [%{path: path, content: cap(content)}]

      _ ->
        []
    end
  end

  defp cap(content) when byte_size(content) <= @max_bytes, do: content

  defp cap(content) do
    String.slice(content, 0, @max_bytes) <> "\n… [truncated]"
  end
end
