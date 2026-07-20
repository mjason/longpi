defmodule Mix.Tasks.Search.Build do
  @shortdoc "Builds the Rust search binary into priv/search"
  @moduledoc """
  Compiles `native/longpi_search` with cargo and copies the binary to
  `priv/search/`, where `Longpi.Search` expects it at runtime.

  The binary embeds ripgrep/fd's engine crates so grep and find run natively
  and cross-platform with no external rg/fd dependency.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    crate = Path.join(File.cwd!(), "native/longpi_search")

    unless System.find_executable("cargo") do
      Mix.raise("cargo not found - install Rust to build the search binary")
    end

    {_, 0} =
      System.cmd("cargo", ["build", "--release", "--quiet"],
        cd: crate,
        into: IO.stream(:stdio, :line)
      )

    bin =
      case :os.type() do
        {:win32, _} -> "longpi_search.exe"
        _ -> "longpi_search"
      end

    dest_dir = Path.join(File.cwd!(), "priv/search")
    dest = Path.join(dest_dir, bin)
    File.mkdir_p!(dest_dir)
    File.cp!(Path.join([crate, "target", "release", bin]), dest)
    File.chmod!(dest, 0o755)
    Mix.shell().info("search built: #{dest}")
  end
end
