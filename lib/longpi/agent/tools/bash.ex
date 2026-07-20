defmodule Longpi.Agent.Tools.Bash do
  @moduledoc """
  Runs a shell command through `Longpi.Shell` (the Rust shim) and formats the
  result for the model: merged PTY output plus footnotes for exit code,
  timeout, and truncation.

  A failed command is still an `{:ok, text}` for the LLM - the model needs to
  read the error output and react; `{:error, _}` is reserved for the tool
  itself being unable to run.
  """

  @behaviour Longpi.Agent.Tool

  @default_timeout_ms 120_000
  @max_timeout_ms 600_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a shell command. Output is a merged terminal stream (stdout+stderr). " <>
      "State does not persist between calls; cwd is the session working directory."
  end

  @impl true
  def parameter_schema do
    [
      command: [type: :string, required: true, doc: "The command to execute"],
      timeout_ms: [
        type: :pos_integer,
        doc: "Kill the command after this many milliseconds (default 120000, max 600000)"
      ]
    ]
  end

  @impl true
  def run(args, ctx) do
    opts = [
      cwd: ctx.cwd,
      timeout_ms: args |> Map.get(:timeout_ms, @default_timeout_ms) |> min(@max_timeout_ms),
      max_output_bytes: Map.get(args, :max_output_bytes, 256 * 1024)
    ]

    case Longpi.Shell.run(args.command, opts) do
      {:ok, result} -> {:ok, format(result)}
      {:error, reason} -> {:error, "shell execution failed: #{inspect(reason)}"}
    end
  end

  defp format(result) do
    body =
      case String.trim(result.output) do
        "" -> "(no output)"
        output -> output
      end

    notes =
      [
        result.exit_code != 0 && "(exit code: #{result.exit_code})",
        result.timed_out? && "(timed out after #{result.duration_ms}ms; process tree killed)",
        result.dropped_bytes > 0 &&
          "(output truncated: #{result.dropped_bytes} bytes dropped#{tail_note(result)})"
      ]
      |> Enum.filter(& &1)

    Enum.join([body | notes], "\n")
  end

  defp tail_note(%{tail: tail}) when is_binary(tail) and tail != "",
    do: "; final output:\n#{tail}"

  defp tail_note(_result), do: ""
end
