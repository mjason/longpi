defmodule Longpi.Agent.Tools.Ls do
  @moduledoc "Lists a directory's entries. Built-in, no external dependency."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

  @impl true
  def name, do: "ls"

  @impl true
  def description do
    "List the entries of a directory. Directories are shown with a trailing slash."
  end

  @impl true
  def parameter_schema do
    [path: [type: :string, doc: "Directory to list (default: cwd)"]]
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
        {:ok, list(path)}
    end
  end

  defp list(path) do
    case path |> File.ls!() |> Enum.sort() do
      [] ->
        "(empty directory)"

      names ->
        Enum.map_join(names, "\n", fn name ->
          if File.dir?(Path.join(path, name)), do: name <> "/", else: name
        end)
    end
  end

  defp display(%{path: path}) when is_binary(path), do: path
  defp display(_args), do: "."
end
