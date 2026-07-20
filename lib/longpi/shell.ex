defmodule Longpi.Shell do
  @moduledoc """
  Runs shell commands through the Rust shim (`native/longpi_shim`).

  This is the single process-execution path in the system: the agent's bash
  tool, and later extension `exec()` callbacks, all go through here. The shim
  provides a PTY, whole-tree kill, and a stdin lifeline that reaps the tree
  even if the BEAM dies uncleanly.

  ## Options

    * `:cwd` - working directory (defaults to the BEAM's cwd)
    * `:env` - extra environment variables, map of string to string
    * `:timeout_ms` - kill the command tree after this long
    * `:max_output_bytes` - head bytes to keep before truncating (default 1 MiB)
    * `:stream_to` / `:ref` - pid to receive `{:shell_output, ref, chunk}`
      and `{:shell_exit, ref, %Result{}}` messages as they happen
    * `:rows` / `:cols` - PTY dimensions

  ## Examples

      {:ok, result} = Longpi.Shell.run("echo hello")
      result.exit_code #=> 0
      result.output    #=> "hello\\r\\n"
  """

  alias Longpi.Shell.Command

  @doc "Runs a command and blocks until it finishes."
  def run(command, opts \\ []) when is_binary(command) do
    with {:ok, pid} <- start(command, opts) do
      Command.await(pid)
    end
  end

  @doc "Starts a command without waiting; interact via `Longpi.Shell.Command`."
  def start(command, opts \\ []) when is_binary(command) do
    DynamicSupervisor.start_child(
      Longpi.Shell.CommandSupervisor,
      {Command, {command, opts}}
    )
  end
end
