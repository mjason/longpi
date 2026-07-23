defmodule Longpi.Agent.Tools.Edit do
  @moduledoc """
  Search-and-replace file editing with layered matching.

  `old_string` is located by trying, in order: an exact match, a match across
  differing line endings (CRLF/LF), then a tolerant line-based match that
  ignores trailing whitespace and normalizes smart quotes / unicode dashes and
  spaces — the differences models routinely introduce. It must identify a
  unique location unless `replace_all` is set (which replaces every exact
  occurrence). The file's own line endings are preserved on write.
  """

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

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
    case locate(content, args.old_string) do
      {:ok, {start, len}, tier} ->
        replacement = adapt_newlines(args.new_string, content)

        updated =
          binary_part(content, 0, start) <>
            replacement <> binary_part(content, start + len, byte_size(content) - start - len)

        if updated == content do
          {:error, "the edit leaves the file unchanged (old and new match) in #{args.path}"}
        else
          File.write!(path, updated)
          {:ok, "edited #{args.path}#{tier_note(tier)}"}
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

  defp tier_note(:exact), do: ""
  defp tier_note(:crlf), do: " (matched across CRLF line endings)"
  defp tier_note(:fuzzy), do: " (matched with whitespace/character normalization)"

  # ── Layered matching ────────────────────────────────────────────────

  defp locate(content, old) do
    case :binary.matches(content, old) do
      [{pos, len}] -> {:ok, {pos, len}, :exact}
      [_ | _] = many -> {:ambiguous, length(many)}
      [] -> locate_crlf(content, old) || locate_fuzzy(content, old) || :not_found
    end
  end

  # The file is CRLF but old_string arrived LF-only (or vice versa).
  defp locate_crlf(content, old) do
    cond do
      String.contains?(content, "\r\n") and not String.contains?(old, "\r\n") ->
        finish_exact(content, String.replace(old, "\n", "\r\n"), :crlf)

      String.contains?(old, "\r\n") ->
        finish_exact(content, String.replace(old, "\r\n", "\n"), :crlf)

      true ->
        nil
    end
  end

  defp finish_exact(content, old, tier) do
    case :binary.matches(content, old) do
      [{pos, len}] -> {:ok, {pos, len}, tier}
      [_ | _] = many -> {:ambiguous, length(many)}
      [] -> nil
    end
  end

  # Whole-line tolerant match: compare lines with trailing whitespace stripped
  # and smart quotes / unicode dashes+spaces normalized, then map the matched
  # window back to the original bytes (keeping the region's final newline).
  defp locate_fuzzy(content, old) do
    lines = physical_lines(content)
    okeys = old |> String.split("\n") |> Enum.map(&line_key/1)
    n = length(okeys)

    with true <- lines != [] and n > 0 and length(lines) >= n,
         ckeys = Enum.map(lines, &line_key/1),
         offsets = line_offsets(lines),
         starts = matching_windows(ckeys, okeys, n),
         [i] <- starts do
      last = i + n - 1
      last_raw = Enum.at(lines, last)
      region_end = Enum.at(offsets, last) + byte_size(last_raw) - byte_size(trailing_newline(last_raw))
      start = Enum.at(offsets, i)
      {:ok, {start, region_end - start}, :fuzzy}
    else
      [_, _ | _] = many -> {:ambiguous, length(many)}
      _ -> nil
    end
  end

  defp matching_windows(ckeys, okeys, n) do
    for i <- 0..(length(ckeys) - n), Enum.slice(ckeys, i, n) == okeys, do: i
  end

  # Physical lines, each including its own trailing newline (last may lack one).
  defp physical_lines(content) do
    ~r/[^\n]*\n|[^\n]+/ |> Regex.scan(content) |> Enum.map(&hd/1)
  end

  defp line_offsets(lines) do
    {_, offsets} =
      Enum.reduce(lines, {0, []}, fn line, {off, acc} -> {off + byte_size(line), [off | acc]} end)

    Enum.reverse(offsets)
  end

  defp trailing_newline(line) do
    cond do
      String.ends_with?(line, "\r\n") -> "\r\n"
      String.ends_with?(line, "\n") -> "\n"
      true -> ""
    end
  end

  # Comparison key for a line: drop the trailing newline + trailing whitespace,
  # NFC-normalize, and fold common typographic variants to ASCII. Leading
  # whitespace (indentation) is kept, so it still has to match.
  defp line_key(line) do
    line
    |> String.trim_trailing()
    |> String.normalize(:nfc)
    |> fold_punctuation()
  end

  defp fold_punctuation(s) do
    s
    |> String.replace(["‘", "’", "‛", "′"], "'")
    |> String.replace(["“", "”", "‟", "″"], "\"")
    |> String.replace(["‐", "‑", "‒", "–", "—", "―", "−"], "-")
    |> String.replace([" ", " ", " ", " ", " ", "　"], " ")
  end

  # Give the replacement the file's dominant line ending.
  defp adapt_newlines(new, content) do
    if String.contains?(content, "\r\n") and not String.contains?(new, "\r\n") do
      String.replace(new, "\n", "\r\n")
    else
      new
    end
  end
end
