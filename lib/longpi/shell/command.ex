defmodule Longpi.Shell.Command do
  @moduledoc """
  One running shell command, wrapping one shim process behind a Port.

  Frame protocol (must match `native/longpi_shim/src/main.rs`):

      BEAM -> shim   0x01 RUN (json)   0x02 KILL (json)
                     0x03 STDIN (raw)  0x04 RESIZE (json)
      shim -> BEAM   0x11 OUTPUT (raw) 0x13 EXIT (json)
                     0x14 ERROR (json) 0x15 TAIL (raw)

  Timeout policy lives here, not in the shim: on `timeout_ms` we send KILL
  with a grace period; if the shim itself stops responding we close the Port,
  which trips the shim's stdin lifeline and takes the process tree with it.
  """

  use GenServer, restart: :temporary

  alias Longpi.Shell.Result

  @f_run 0x01
  @f_kill 0x02
  @f_stdin 0x03
  @f_resize 0x04
  @f_output 0x11
  @f_exit 0x13
  @f_error 0x14
  @f_tail 0x15

  @kill_grace_ms 5_000
  @port_close_margin_ms 2_000

  def start_link({command, opts}) do
    GenServer.start_link(__MODULE__, {command, opts})
  end

  @doc "Blocks until the command finishes; returns `{:ok, %Result{}}`."
  def await(pid), do: GenServer.call(pid, :await, :infinity)

  @doc "Requests early termination (SIGTERM -> grace -> SIGKILL)."
  def kill(pid), do: GenServer.cast(pid, :kill)

  @doc "Sends bytes to the command's stdin (PTY input)."
  def send_input(pid, data), do: GenServer.cast(pid, {:input, data})

  @doc "Resizes the PTY."
  def resize(pid, rows, cols), do: GenServer.cast(pid, {:resize, rows, cols})

  @impl true
  def init({command, opts}) do
    shim = shim_path()

    if File.exists?(shim) do
      {:ok, do_init(shim, command, opts)}
    else
      {:stop, {:shim_not_built, shim}}
    end
  end

  defp do_init(shim, command, opts) do
    port =
      Port.open({:spawn_executable, shim}, [
        :binary,
        {:packet, 4},
        :exit_status,
        args: []
      ])

    {exe, args} = shell_argv(command)

    run = %{
      argv: [exe | args],
      cwd: opts[:cwd] || File.cwd!(),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      rows: opts[:rows] || 24,
      cols: opts[:cols] || 80,
      max_output_bytes: opts[:max_output_bytes] || 1024 * 1024
    }

    Port.command(port, [@f_run, Jason.encode!(run)])

    timeout_ref =
      if timeout = opts[:timeout_ms] do
        Process.send_after(self(), :timeout, timeout)
      end

    %{
      port: port,
      output: [],
      tail: nil,
      timed_out?: false,
      timeout_ref: timeout_ref,
      started_at: System.monotonic_time(:millisecond),
      stream_to: opts[:stream_to],
      ref: opts[:ref],
      # Monitor the owner (the agent's turn task). If it dies — e.g. the user
      # interrupts the turn — we stop, and terminate/2 closes the Port, reaping
      # the whole child process tree. Otherwise a long command would keep
      # running invisibly after "stop".
      owner_mon: monitor_owner(opts[:stream_to]),
      awaiting: [],
      result: nil
    }
  end

  defp monitor_owner(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_owner(_), do: nil

  @impl true
  def handle_call(:await, from, state) do
    case state.result do
      nil -> {:noreply, %{state | awaiting: [from | state.awaiting]}}
      result -> {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_cast(:kill, state), do: {:noreply, start_kill(state)}

  def handle_cast({:input, data}, state) do
    Port.command(state.port, [@f_stdin, data])
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, state) do
    Port.command(state.port, [@f_resize, Jason.encode!(%{rows: rows, cols: cols})])
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, <<@f_output, chunk::binary>>}}, %{port: port} = state) do
    notify(state, {:shell_output, state.ref, chunk})
    {:noreply, %{state | output: [state.output | chunk]}}
  end

  def handle_info({port, {:data, <<@f_tail, chunk::binary>>}}, %{port: port} = state) do
    {:noreply, %{state | tail: chunk}}
  end

  def handle_info({port, {:data, <<@f_exit, json::binary>>}}, %{port: port} = state) do
    %{"exit_code" => code, "dropped_bytes" => dropped} = Jason.decode!(json)

    result = %Result{
      output: IO.iodata_to_binary(state.output),
      tail: state.tail,
      exit_code: code,
      dropped_bytes: dropped,
      timed_out?: state.timed_out?,
      duration_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:noreply, finish(state, result)}
  end

  def handle_info({port, {:data, <<@f_error, json::binary>>}}, %{port: port} = state) do
    %{"message" => message} = Jason.decode!(json)
    fail_awaiting(state, {:shim_error, message})
    {:stop, :normal, %{state | awaiting: []}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    case state.result do
      # Normal: EXIT frame already handled; linger until :shutdown so late
      # await/1 callers still get the result.
      %Result{} ->
        {:noreply, state}

      nil ->
        fail_awaiting(state, {:shim_died, status})
        {:stop, :normal, %{state | awaiting: []}}
    end
  end

  def handle_info(:timeout, state) do
    {:noreply, start_kill(%{state | timed_out?: true})}
  end

  def handle_info(:shutdown, state), do: {:stop, :normal, state}

  # Owner (turn task) went down — interrupt. Stopping closes the Port, which
  # tears down the command's whole process tree.
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{owner_mon: mon} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:force_close, state) do
    # Shim unresponsive after KILL + grace: close the Port. The stdin
    # lifeline in the shim kills the tree even if its control loop is stuck.
    if state.result == nil do
      safe_close(state.port)
      fail_awaiting(state, :killed_unresponsive)
      {:stop, :normal, %{state | awaiting: []}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Crash-safety net: closing the Port always tears down the child tree.
    safe_close(state.port)
  end

  defp start_kill(state) do
    Port.command(state.port, [@f_kill, Jason.encode!(%{grace_ms: @kill_grace_ms})])
    Process.send_after(self(), :force_close, @kill_grace_ms + @port_close_margin_ms)
    state
  end

  defp finish(state, result) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    notify(state, {:shell_exit, state.ref, result})
    Enum.each(state.awaiting, &GenServer.reply(&1, {:ok, result}))
    # Linger briefly for late await calls; the shim process is already gone.
    Process.send_after(self(), :shutdown, 5_000)
    %{state | result: result, awaiting: []}
  end

  defp fail_awaiting(state, reason) do
    notify(state, {:shell_error, state.ref, reason})
    Enum.each(state.awaiting, &GenServer.reply(&1, {:error, reason}))
  end

  defp notify(%{stream_to: pid, ref: ref}, message) when is_pid(pid) and not is_nil(ref) do
    send(pid, message)
  end

  defp notify(_state, _message), do: :ok

  defp safe_close(port) do
    if port && Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp shell_argv(command) do
    case :os.type() do
      {:win32, _} ->
        # TODO(windows): prefer Git Bash when detected; PowerShell fallback.
        {"powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command]}

      _ ->
        {System.find_executable("bash") || "/bin/sh", ["-c", command]}
    end
  end

  defp shim_path do
    Application.get_env(:longpi, :shim_path) ||
      Path.join([:code.priv_dir(:longpi), "shim", shim_binary_name()])
  end

  defp shim_binary_name do
    case :os.type() do
      {:win32, _} -> "longpi_shim.exe"
      _ -> "longpi_shim"
    end
  end
end
