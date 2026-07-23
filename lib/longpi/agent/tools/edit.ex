defmodule Longpi.Agent.Tools.Edit do
  @moduledoc """
  Search-and-replace file editing with layered matching.

  `old_string` is located by trying, in order: an exact match, a match across
  differing line endings (CRLF/LF), then a tolerant line-based match that
  ignores trailing whitespace and normalizes smart quotes / unicode dashes and
  spaces — the differences models routinely introduce. It must identify a
  unique location unless `replace_all` is set (which replaces every exact
  occurrence). The file's own line endings are preserved on write.

  The matching core lives in `Longpi.Agent.Edit`, shared with `apply_patch`.
  """

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.{Edit, Tool}

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Replace old_string with new_string in a file. Matching is exact first, " <>
      "then tolerant of line-ending and trailing-whitespace differences. " <>
      "old_string must identify a unique location unless replace_all is true. " <>
      "To make several edits, call this tool once per edit (they run together)."
  end

  @impl true
  def parameter_schema do
    [
      path: [type: :string, required: true, doc: "File path, absolute or relative to cwd"],
      old_string: [type: :string, required: true, doc: "Text to find (copy it from the file)"],
      new_string: [type: :string, required: true, doc: "Replacement text"],
      replace_all: [type: :boolean, default: false, doc: "Replace every exact occurrence"]
    ]
  end

  @impl true
  def run(args, ctx) do
    path = Tool.resolve_path(args.path, ctx)

    with :ok <- validate_strings(args),
         {:ok, content} <- read(path, args.path) do
      edit(content, args, path)
    end
  end

  defp validate_strings(%{old_string: same, new_string: same}),
    do: {:error, "old_string and new_string are identical — nothing to change"}

  defp validate_strings(%{old_string: ""}),
    do: {:error, "old_string must not be empty"}

  defp validate_strings(_args), do: :ok

  defp read(path, display_path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, "file not found: #{display_path}"}
    end
  end

  # replace_all keeps exact-only semantics: rename every literal occurrence.
  defp edit(content, %{replace_all: true} = args, path) do
    case content |> :binary.matches(args.old_string) |> length() do
      0 ->
        {:error, not_found(args.path)}

      n ->
        File.write!(path, String.replace(content, args.old_string, args.new_string))
        {:ok, "replaced #{n} occurrence(s) in #{args.path}"}
    end
  end

  defp edit(content, args, path) do
    case Edit.replace(content, args.old_string, args.new_string) do
      {:ok, updated, tier} ->
        if updated == content do
          {:error, "the edit leaves the file unchanged (old and new match) in #{args.path}"}
        else
          File.write!(path, updated)
          {:ok, "edited #{args.path}#{Edit.tier_note(tier)}"}
        end

      {:ambiguous, n} ->
        {:error,
         "old_string matches #{n} places in #{args.path}; add surrounding lines to make it " <>
           "unique, or set replace_all"}

      :not_found ->
        {:error, not_found(args.path)}
    end
  end

  defp not_found(path) do
    "old_string not found in #{path}. It must match the file's text — exact, or close enough " <>
      "after normalizing line endings and trailing whitespace. Re-read the file and copy the " <>
      "exact lines, or include more surrounding context."
  end
end
