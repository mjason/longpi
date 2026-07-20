defmodule Longpi.Agent.Tools.Edit do
  @moduledoc """
  Exact-string replacement in a file.

  `old_string` must match exactly once unless `replace_all` is set; ambiguity
  is an error so the model adds more context rather than editing blind.
  """

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Replace old_string with new_string in a file. " <>
      "old_string must be unique in the file unless replace_all is true."
  end

  @impl true
  def parameter_schema do
    [
      path: [type: :string, required: true, doc: "File path, absolute or relative to cwd"],
      old_string: [type: :string, required: true, doc: "Exact text to replace"],
      new_string: [type: :string, required: true, doc: "Replacement text"],
      replace_all: [type: :boolean, default: false, doc: "Replace every occurrence"]
    ]
  end

  @impl true
  def run(args, ctx) do
    path = Tool.resolve_path(args.path, ctx)

    with :ok <- validate_strings(args),
         {:ok, content} <- read(path, args.path) do
      replace(content, args, path)
    end
  end

  defp validate_strings(%{old_string: same, new_string: same}),
    do: {:error, "old_string and new_string must be different"}

  defp validate_strings(%{old_string: ""}),
    do: {:error, "old_string must not be empty"}

  defp validate_strings(_args), do: :ok

  defp read(path, display_path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, "file not found: #{display_path}"}
    end
  end

  defp replace(content, args, path) do
    occurrences = content |> :binary.matches(args.old_string) |> length()
    replace_all = Map.get(args, :replace_all, false)

    cond do
      occurrences == 0 ->
        {:error, "old_string not found in #{args.path}"}

      occurrences > 1 and not replace_all ->
        {:error,
         "old_string appears #{occurrences} times in #{args.path}; " <>
           "add surrounding context to make it unique, or set replace_all"}

      true ->
        File.write!(path, String.replace(content, args.old_string, args.new_string))
        {:ok, "replaced #{occurrences} occurrence(s) in #{args.path}"}
    end
  end
end
