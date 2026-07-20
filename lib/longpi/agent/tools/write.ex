defmodule Longpi.Agent.Tools.Write do
  @moduledoc "Writes (creates or overwrites) a file, creating parent directories."

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Write content to a file, overwriting if it exists. Parent directories are created."
  end

  @impl true
  def parameter_schema do
    [
      path: [type: :string, required: true, doc: "File path, absolute or relative to cwd"],
      content: [type: :string, required: true, doc: "Full file content to write"]
    ]
  end

  @impl true
  def run(args, ctx) do
    path = Tool.resolve_path(args.path, ctx)

    with :ok <- ensure_not_dir(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, args.content) do
      {:ok, "wrote #{byte_size(args.content)} bytes to #{args.path}"}
    else
      {:error, reason} -> {:error, "cannot write #{args.path}: #{describe(reason)}"}
    end
  end

  defp ensure_not_dir(path) do
    if File.dir?(path), do: {:error, :eisdir}, else: :ok
  end

  defp describe(:eisdir), do: "target is a directory"
  defp describe(posix), do: posix |> :file.format_error() |> List.to_string()
end
