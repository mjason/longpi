defmodule Longpi.Agent.Tools.Ls do
  @moduledoc "Lists a directory's entries. Built-in, no external dependency."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

  @impl true
  def name, do: "ls"

  @default_limit 500

  @impl true
  def description do
    "List the entries of a directory. Directories are shown with a trailing " <>
      "slash. Returns at most 500 entries unless limit is set."
  end

  @impl true
  def parameter_schema do
    [
      path: [type: :string, doc: "Directory to list (default: cwd)"],
      limit: [type: :pos_integer, doc: "Maximum entries to return (default 500)"]
    ]
  end

  @impl true
  def run(args, ctx) do
    path = args |> Map.get(:path, ".") |> Tool.resolve_path(ctx)

    cond do
      not File.exists?(path) ->
        {:error, "path not found: #{display(args)}"}

      not File.dir?(path) ->
        {:error, "not a directory: #{display(args)}"}

      true ->
        {:ok, list(path, Map.get(args, :limit, @default_limit))}
    end
  end

  defp list(path, limit) do
    # Case-insensitive sort reads more naturally than raw codepoint order.
    names = path |> File.ls!() |> Enum.sort_by(&String.downcase/1)

    case names do
      [] ->
        "(empty directory)"

      names ->
        shown = Enum.take(names, limit)

        body =
          Enum.map_join(shown, "\n", fn name ->
            if File.dir?(Path.join(path, name)), do: name <> "/", else: name
          end)

        if length(names) > limit do
          body <>
            "\n[truncated: showing #{limit} of #{length(names)} entries; raise limit or narrow the path]"
        else
          body
        end
    end
  end

  defp display(%{path: path}) when is_binary(path), do: path
  defp display(_args), do: "."
end
