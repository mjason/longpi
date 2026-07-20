defmodule Mix.Tasks.Shim.Build do
  @shortdoc "Builds the Rust shell shim into priv/shim"
  @moduledoc """
  Compiles `native/longpi_shim` with cargo and copies the binary to
  `priv/shim/`, where `Longpi.Shell` expects it at runtime.

  Requires a Rust toolchain in dev; releases ship a prebuilt binary.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    crate = Path.join(File.cwd!(), "native/longpi_shim")

    unless System.find_executable("cargo") do
      Mix.raise("cargo not found - install Rust to build the shell shim")
    end

    {_, 0} =
      System.cmd("cargo", ["build", "--release", "--quiet"],
        cd: crate,
        into: IO.stream(:stdio, :line)
      )

    bin =
      case :os.type() do
        {:win32, _} -> "longpi_shim.exe"
        _ -> "longpi_shim"
      end

    dest_dir = Path.join(File.cwd!(), "priv/shim")
    dest = Path.join(dest_dir, bin)
    File.mkdir_p!(dest_dir)
    File.cp!(Path.join([crate, "target", "release", bin]), dest)
    File.chmod!(dest, 0o755)
    Mix.shell().info("shim built: #{dest}")
  end
end
