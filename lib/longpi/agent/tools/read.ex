defmodule Longpi.Agent.Tools.Read do
  @moduledoc "Reads a file from the workspace, with optional line windowing."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

  @default_limit 2000

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a file. Returns its content; use offset/limit (1-based lines) for large files."
  end

  @impl true
  def parameter_schema do
    [
      path: [type: :string, required: true, doc: "File path, absolute or relative to cwd"],
      offset: [type: :pos_integer, doc: "First line to read (1-based)"],
      limit: [type: :pos_integer, doc: "Maximum number of lines to return"]
    ]
  end

  @impl true
  def run(args, ctx) do
    path = Tool.resolve_path(args.path, ctx)

    cond do
      File.dir?(path) ->
        {:error, "#{args.path} is a directory, not a file"}

      not File.exists?(path) ->
        {:error, "file not found: #{args.path}"}

      true ->
        {:ok, window(File.read!(path), args[:offset], args[:limit])}
    end
  end

  defp window(content, nil, nil) do
    lines = String.split(content, "\n")
    total = length(lines)

    if total <= @default_limit do
      content
    else
      head = lines |> Enum.take(@default_limit) |> Enum.join("\n")

      head <>
        "\n[truncated: showing lines 1-#{@default_limit} of #{total}; use offset to read more]"
    end
  end

  defp window(content, offset, limit) do
    offset = offset || 1
    limit = limit || @default_limit
    lines = String.split(content, "\n")
    total = length(lines)
    slice = lines |> Enum.drop(offset - 1) |> Enum.take(limit)

    case slice do
      [] ->
        "[no content: file has #{total} lines, offset #{offset} is past the end]"

      _ ->
        last = offset + length(slice) - 1
        Enum.join(slice, "\n") <> "\n[lines #{offset}-#{last} of #{total}]"
    end
  end
end
