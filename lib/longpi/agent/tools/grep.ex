defmodule Longpi.Agent.Tools.Grep do
  @moduledoc "Searches file contents with ripgrep's engine, via `Longpi.Search`."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Search

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search file contents for a regex (or literal). Respects .gitignore. " <>
      "Returns matching lines as path:line:text."
  end

  @impl true
  def parameter_schema do
    [
      pattern: [
        type: :string,
        required: true,
        doc: "Regex pattern, or literal text if literal:true"
      ],
      path: [type: :string, doc: "Directory or file to search (default: cwd)"],
      glob: [type: :string, doc: "Filter files by glob, e.g. '*.ex' or '**/*.spec.ts'"],
      ignore_case: [type: :boolean, default: false, doc: "Case-insensitive search"],
      literal: [type: :boolean, default: false, doc: "Treat pattern as literal text, not regex"],
      context: [
        type: :non_neg_integer,
        default: 0,
        doc: "Lines of context before and after each match"
      ],
      limit: [type: :pos_integer, doc: "Maximum matches to return (default 100)"]
    ]
  end

  @impl true
  def run(args, ctx) do
    payload =
      args
      |> Map.take([:pattern, :glob, :ignore_case, :literal, :context, :limit])
      |> put_path(args, ctx)

    case Search.grep(payload, cwd: ctx.cwd) do
      {:ok, result} -> {:ok, format(result)}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
    end
  end

  defp put_path(payload, %{path: path}, _ctx) when is_binary(path),
    do: Map.put(payload, :path, path)

  defp put_path(payload, _args, _ctx), do: payload

  defp format(%{"matches" => []}), do: "No matches found."

  defp format(%{"matches" => matches} = result) do
    body =
      matches
      |> Enum.map_join("\n", fn
        %{"kind" => "match", "path" => p, "line" => l, "text" => t} -> "#{p}:#{l}: #{t}"
        %{"path" => p, "line" => l, "text" => t} -> "#{p}-#{l}- #{t}"
      end)

    if result["limit_reached"] do
      body <> "\n[truncated at #{result["count"]} match limit; narrow the pattern or path]"
    else
      body
    end
  end
end
