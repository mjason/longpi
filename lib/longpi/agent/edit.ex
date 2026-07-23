defmodule Longpi.Agent.Edit do
  @moduledoc """
  Layered search-and-replace core, shared by the `edit` and `apply_patch` tools.

  `old_string` is located by trying, in order: an exact match, a match across
  differing line endings (CRLF/LF), then a tolerant line-based match that
  ignores trailing whitespace and normalizes smart quotes / unicode dashes and
  spaces — the differences models routinely introduce. The replacement is given
  the file's dominant line ending.
  """

  @type tier :: :exact | :crlf | :fuzzy

  @doc """
  Replaces the single location of `old_string` in `content` with `new_string`.

  Returns `{:ok, new_content, tier}`, `{:ambiguous, count}` when `old_string`
  matches more than one place, or `:not_found`.
  """
  @spec replace(binary(), binary(), binary()) ::
          {:ok, binary(), tier()} | {:ambiguous, pos_integer()} | :not_found
  def replace(content, old_string, new_string) do
    case locate(content, old_string) do
      {:ok, {start, len}, tier} ->
        replacement = adapt_newlines(new_string, content)

        updated =
          binary_part(content, 0, start) <>
            replacement <> binary_part(content, start + len, byte_size(content) - start - len)

        {:ok, updated, tier}

      other ->
        other
    end
  end

  @doc "Human note describing which matching tier was used (empty for exact)."
  @spec tier_note(tier()) :: binary()
  def tier_note(:exact), do: ""
  def tier_note(:crlf), do: " (matched across CRLF line endings)"
  def tier_note(:fuzzy), do: " (matched with whitespace/character normalization)"

  @doc "Gives `text` the file's dominant line ending (CRLF when `content` is CRLF)."
  @spec adapt_newlines(binary(), binary()) :: binary()
  def adapt_newlines(new, content) do
    if String.contains?(content, "\r\n") and not String.contains?(new, "\r\n") do
      String.replace(new, "\n", "\r\n")
    else
      new
    end
  end

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
    |> String.replace([" ", " ", " ", " ", " ", "　"], " ")
  end
end
