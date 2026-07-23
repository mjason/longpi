defmodule Longpi.Agent.Tools.ApplyPatch do
  @moduledoc """
  Applies a Codex-style patch (the `*** Begin Patch` / `*** Update File` / `@@`
  envelope models are trained to emit) so a habitual `apply_patch` call just
  works instead of failing.

  Each update hunk is turned into an (old, new) text pair and applied with
  `Longpi.Agent.Edit.replace/3` — the same layered matching the `edit` tool
  uses — so it tolerates line-ending and whitespace drift and never relies on
  the patch's line numbers. Add/Delete sections write and remove whole files.
  """

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.{Edit, Tool}

  @impl true
  def name, do: "apply_patch"

  @impl true
  def description do
    "Apply a patch in the *** Begin Patch / *** Update File / @@ / +/- format. " <>
      "Prefer this for multi-hunk or multi-file changes; use edit for a single " <>
      "targeted replacement. Hunks are matched by context, not line numbers, so " <>
      "include a few surrounding unchanged lines (prefixed with a space)."
  end

  @impl true
  def parameter_schema do
    [
      input: [
        type: :string,
        required: true,
        doc:
          "The full patch text. Wrap file sections in *** Begin Patch / *** End Patch. " <>
            "Sections: *** Update File: <path> (with @@ hunks of space/+/- lines), " <>
            "*** Add File: <path> (with + lines), *** Delete File: <path>."
      ]
    ]
  end

  @impl true
  def run(%{input: input}, ctx) when is_binary(input) do
    with {:ok, ops} <- parse(input) do
      apply_ops(ops, ctx)
    end
  end

  # ── Parsing ─────────────────────────────────────────────────────────

  defp parse(input) do
    lines =
      input
      |> String.split("\n")
      |> Enum.reject(&(&1 in ["*** Begin Patch", "*** End Patch"]))

    case parse_ops(lines, []) do
      {:ok, []} ->
        {:error,
         "no file sections found in patch — expected *** Update File, *** Add File, or *** Delete File"}

      other ->
        other
    end
  end

  defp parse_ops([], acc), do: {:ok, Enum.reverse(acc)}
  defp parse_ops(["" | rest], acc), do: parse_ops(rest, acc)

  defp parse_ops([line | rest], acc) do
    cond do
      prefixed?(line, "*** Add File: ") ->
        {body, rest2} = take_section(rest)
        parse_ops(rest2, [{:add, suffix(line, "*** Add File: "), add_content(body)} | acc])

      prefixed?(line, "*** Delete File: ") ->
        {_body, rest2} = take_section(rest)
        parse_ops(rest2, [{:delete, suffix(line, "*** Delete File: ")} | acc])

      prefixed?(line, "*** Update File: ") ->
        path = suffix(line, "*** Update File: ")
        {move, rest1} = take_move(rest)
        {body, rest2} = take_section(rest1)
        parse_ops(rest2, [{:update, path, move, parse_hunks(body)} | acc])

      true ->
        {:error,
         "unexpected line in patch: #{inspect(line)} — expected a *** Update/Add/Delete File section"}
    end
  end

  # A Move-to line, when present, immediately follows *** Update File.
  defp take_move([line | rest]) do
    if prefixed?(line, "*** Move to: "), do: {suffix(line, "*** Move to: "), rest}, else: {nil, [line | rest]}
  end

  defp take_move([]), do: {nil, []}

  # Lines up to (but not consuming) the next *** directive.
  defp take_section(lines), do: Enum.split_while(lines, &(not String.starts_with?(&1, "*** ")))

  defp add_content(body) do
    lines = body |> Enum.filter(&String.starts_with?(&1, "+")) |> Enum.map(&strip1/1)
    if lines == [], do: "", else: Enum.join(lines, "\n") <> "\n"
  end

  defp parse_hunks(body) do
    body
    |> group_hunks()
    |> Enum.map(&to_hunk/1)
    |> Enum.reject(fn {old, new} -> old == "" and new == "" end)
  end

  # Split hunk-body lines at `@@` markers into one line-list per hunk.
  defp group_hunks(body) do
    {groups, current} =
      Enum.reduce(body, {[], []}, fn line, {groups, current} ->
        if String.starts_with?(line, "@@"),
          do: {push(groups, current), []},
          else: {groups, [line | current]}
      end)

    push(groups, current) |> Enum.reverse() |> Enum.map(&Enum.reverse/1)
  end

  defp push(groups, []), do: groups
  defp push(groups, current), do: [current | groups]

  # A hunk's old text = context + removed lines; new text = context + added.
  defp to_hunk(lines) do
    classified = Enum.map(lines, &classify/1)
    old = collect(classified, [:ctx, :del])
    new = collect(classified, [:ctx, :add])
    {old, new}
  end

  defp collect(classified, kinds) do
    classified
    |> Enum.filter(fn {kind, _} -> kind in kinds end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.join("\n")
  end

  defp classify("+" <> rest), do: {:add, rest}
  defp classify("-" <> rest), do: {:del, rest}
  defp classify(" " <> rest), do: {:ctx, rest}
  # A bare blank line is a context blank; anything else is tolerated as context
  # (a model that dropped the leading space on an unchanged line).
  defp classify(line), do: {:ctx, line}

  # ── Applying ────────────────────────────────────────────────────────

  defp apply_ops(ops, ctx) do
    result =
      Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, notes} ->
        case apply_op(op, ctx) do
          {:ok, note} -> {:cont, {:ok, [note | notes]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, notes} -> {:ok, notes |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp apply_op({:add, path, content}, ctx) do
    abs = Tool.resolve_path(path, ctx)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
    {:ok, "added #{path}"}
  end

  defp apply_op({:delete, path}, ctx) do
    case File.rm(Tool.resolve_path(path, ctx)) do
      :ok -> {:ok, "deleted #{path}"}
      {:error, _} -> {:error, "cannot delete #{path}: file not found"}
    end
  end

  defp apply_op({:update, path, move, hunks}, ctx) do
    abs = Tool.resolve_path(path, ctx)

    with {:ok, content} <- read(abs, path),
         {:ok, updated} <- apply_hunks(content, hunks, path) do
      target = if move, do: Tool.resolve_path(move, ctx), else: abs
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, updated)
      if move && Tool.resolve_path(move, ctx) != abs, do: File.rm(abs)
      {:ok, "updated #{path}#{if move, do: " -> #{move}", else: ""}"}
    end
  end

  defp read(abs, path) do
    case File.read(abs) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, "cannot update #{path}: file not found"}
    end
  end

  defp apply_hunks(content, hunks, path) do
    Enum.reduce_while(hunks, {:ok, content}, fn {old, new}, {:ok, current} ->
      if old == "" do
        {:halt, {:error, "a hunk for #{path} has no context or removed lines to locate; add surrounding lines"}}
      else
        case Edit.replace(current, old, new) do
          {:ok, updated, _tier} ->
            {:cont, {:ok, updated}}

          {:ambiguous, n} ->
            {:halt, {:error, "a hunk matches #{n} places in #{path}; include more surrounding context"}}

          :not_found ->
            {:halt, {:error, "a hunk did not match #{path}; re-read the file and regenerate the patch"}}
        end
      end
    end)
  end

  # ── Small helpers ───────────────────────────────────────────────────

  defp prefixed?(line, prefix), do: String.starts_with?(line, prefix)
  defp suffix(line, prefix), do: line |> String.replace_prefix(prefix, "") |> String.trim()
  defp strip1(line), do: binary_part(line, 1, byte_size(line) - 1)
end
