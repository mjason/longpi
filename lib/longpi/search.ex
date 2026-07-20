defmodule Longpi.Search do
  @moduledoc """
  Runs the Rust search binary (`native/longpi_search`) for the grep and find
  tools.

  The binary embeds ripgrep/fd's engine crates, so search is native and
  cross-platform with no external rg/fd dependency. Args go in as one JSON
  argv (no shell, so no quoting or injection), results come back as JSON on
  stdout.
  """

  @spec grep(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def grep(args, opts \\ []), do: run("grep", args, opts)

  @spec find(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def find(args, opts \\ []), do: run("find", args, opts)

  defp run(command, args, opts) do
    bin = binary_path()

    if File.exists?(bin) do
      cwd = opts[:cwd] || File.cwd!()

      # On success the binary writes only JSON to stdout; on failure only an
      # error message to stderr. Folding stderr into the captured output lets
      # us surface that message (System.cmd's first element is stdout only).
      case System.cmd(bin, [command, Jason.encode!(args)], cd: cwd, stderr_to_stdout: true) do
        {output, 0} -> {:ok, Jason.decode!(output)}
        {output, _code} -> {:error, String.trim(output)}
      end
    else
      {:error, {:search_not_built, bin}}
    end
  end

  defp binary_path do
    Application.get_env(:longpi, :search_path) ||
      Path.join([:code.priv_dir(:longpi), "search", binary_name()])
  end

  defp binary_name do
    case :os.type() do
      {:win32, _} -> "longpi_search.exe"
      _ -> "longpi_search"
    end
  end
end
