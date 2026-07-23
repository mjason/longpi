defmodule Longpi.Agent.Tools.Read do
  @moduledoc "Reads a file from the workspace, with optional line windowing."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

  @default_limit 2000
  # Byte ceiling on returned content, independent of the line cap — a file with
  # very long lines (minified JS, JSON, base64) is one "line" but can be
  # megabytes, so the line cap alone won't protect the context window.
  @max_bytes 50_000

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a file. Returns its content with a truncation note when clipped: " <>
      "without offset/limit it returns at most the first 2000 lines. Use " <>
      "offset/limit (1-based lines) to page through larger files."
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
        {:ok, path |> File.read!() |> window(args[:offset], args[:limit]) |> cap_bytes()}
    end
  end

  # Keep the returned text under the byte ceiling, cutting at a valid UTF-8
  # boundary so the model never receives mojibake.
  defp cap_bytes(text) when byte_size(text) <= @max_bytes, do: text

  defp cap_bytes(text) do
    <<head::binary-size(@max_bytes), _::binary>> = text

    trim_to_valid(head) <>
      "\n[truncated: output exceeded #{@max_bytes} bytes; use offset/limit to page, or grep to search]"
  end

  defp trim_to_valid(bin) do
    if String.valid?(bin), do: bin, else: trim_to_valid(binary_part(bin, 0, byte_size(bin) - 1))
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
