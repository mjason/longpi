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
  # 30 min ceiling — long enough for real builds/installs/test suites (the old
  # 10 min cap killed legitimate long jobs).
  @max_timeout_ms 1_800_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a shell command. Output is a merged terminal stream (stdout+stderr), " <>
      "capped at 256KB with the middle dropped when longer. State does not " <>
      "persist between calls; cwd is the session working directory."
  end

  @impl true
  def parameter_schema do
    [
      command: [type: :string, required: true, doc: "The command to execute"],
      timeout_ms: [
        type: :pos_integer,
        doc: "Kill the command after this many milliseconds (default 120000, max 1800000)"
      ]
    ]
  end

  @impl true
  def run(args, ctx) do
    if not File.dir?(ctx.cwd) do
      {:error, "working directory does not exist: #{ctx.cwd}"}
    else
      run_command(args, ctx)
    end
  end

  defp run_command(args, ctx) do
    ref = make_ref()

    opts = [
      cwd: ctx.cwd,
      timeout_ms: args |> Map.get(:timeout_ms, @default_timeout_ms) |> min(@max_timeout_ms),
      max_output_bytes: Map.get(args, :max_output_bytes, 256 * 1024),
      # Stream output live so long-running commands report progress, and so the
      # shim dies with this turn task (see Longpi.Shell.Command owner monitor).
      stream_to: self(),
      ref: ref
    ]

    case Longpi.Shell.start(args.command, opts) do
      {:ok, _pid} ->
        case collect(ref, ctx[:progress]) do
          {:ok, result} -> {:ok, format(result)}
          {:error, reason} -> {:error, "shell execution failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "shell execution failed: #{inspect(reason)}"}
    end
  end

  # Forward each output chunk to the progress callback (live UI), then return
  # the final result. Running inside the turn task means an interrupt kills this
  # receive and, via the owner monitor, the shim.
  defp collect(ref, progress) do
    receive do
      {:shell_output, ^ref, chunk} ->
        if is_function(progress, 1), do: progress.(chunk)
        collect(ref, progress)

      {:shell_exit, ^ref, result} ->
        {:ok, result}

      {:shell_error, ^ref, reason} ->
        {:error, reason}
    end
  end

  defp format(result) do
    body =
      case result.output |> strip_terminal_noise() |> String.trim() do
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

  # The shim runs commands under a pty, so tools (uv, npm, cargo) emit ANSI
  # color codes and \r-redrawn progress frames. Both pollute the model's
  # context AND render as garbage in the UI ("[2m[32m…") — strip escape
  # sequences and keep only the FINAL frame of every \r-rewritten line.
  defp strip_terminal_noise(output) do
    output
    # CSI sequences (colors, cursor movement): ESC [ params letter
    |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
    # OSC sequences (titles, hyperlinks): ESC ] ... BEL or ESC \
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\)/, "")
    # Stray non-CSI escapes
    |> String.replace(~r/\e[@-Z\\-_]/, "")
    # pty line endings, then collapse \r redraws to the last frame per line
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(fn line -> line |> String.split("\r") |> List.last() end)
    |> Enum.join("\n")
  end

  defp tail_note(%{tail: tail}) when is_binary(tail) and tail != "",
    do: "; final output:\n#{tail}"

  defp tail_note(_result), do: ""
end
