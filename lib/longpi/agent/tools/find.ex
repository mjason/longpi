defmodule Longpi.Agent.Tools.Find do
  @moduledoc "Finds files by glob with fd's engine, via `Longpi.Search`."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Search

  @impl true
  def name, do: "find"

  @impl true
  def description do
    "Find files by glob pattern. Respects .gitignore. Returns matching paths " <>
      "relative to the search directory."
  end

  @impl true
  def parameter_schema do
    [
      pattern: [
        type: :string,
        required: true,
        doc: "Glob, e.g. '*.ex', '**/*.json', 'src/**/*.ex'"
      ],
      path: [type: :string, doc: "Directory to search (default: cwd)"],
      limit: [type: :pos_integer, doc: "Maximum files to return (default 1000)"]
    ]
  end

  @impl true
  def run(args, ctx) do
    payload = args |> Map.take([:pattern, :limit]) |> put_path(args)

    case Search.find(payload, cwd: ctx.cwd) do
      {:ok, result} -> {:ok, format(result)}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
    end
  end

  defp put_path(payload, %{path: path}) when is_binary(path), do: Map.put(payload, :path, path)
  defp put_path(payload, _args), do: payload

  defp format(%{"files" => []}), do: "No files found."

  defp format(%{"files" => files} = result) do
    body = Enum.join(files, "\n")

    if result["limit_reached"] do
      body <> "\n[truncated at #{result["count"]} file limit; narrow the pattern or path]"
    else
      body
    end
  end
end
