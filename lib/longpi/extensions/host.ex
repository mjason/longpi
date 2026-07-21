defmodule Longpi.Extensions.Host do
  @moduledoc """
  Manages one Bun extension-host process for a session's working directory.

  The Elixir brain owns the agent loop; this Bun process (see
  `priv/ext_host/host.ts`) owns extension module loading and tool execution,
  mirroring pi's extension model across an IPC boundary. Framing is Erlang's
  `{:packet, 4}` (4-byte length prefix) carrying JSON both ways.

  The host is best-effort: if Bun isn't installed, `start_for/1` returns
  `:none` and the session simply runs with only its built-in tools.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Longpi.Agent.ToolSpec

  @call_timeout 120_000

  # Client

  @doc """
  Starts a host for `cwd`, or returns `:none` when Bun is unavailable so the
  caller can degrade to built-in tools only.
  """
  @spec start_for(String.t()) :: {:ok, pid()} | :none
  def start_for(cwd) do
    case find_bun() do
      {:ok, _bun} ->
        case GenServer.start_link(__MODULE__, cwd) do
          {:ok, pid} -> {:ok, pid}
          _ -> :none
        end

      :error ->
        :none
    end
  end

  @doc "Tool specs for every extension-registered tool (waits for load)."
  @spec tool_specs(pid()) :: [ToolSpec.t()]
  def tool_specs(host), do: GenServer.call(host, :tool_specs, 15_000)

  @doc "Runs an extension tool in the host, returning `{:ok, text}`/`{:error, text}`."
  @spec call_tool(pid(), String.t(), map()) :: {:ok, binary()} | {:error, binary()}
  def call_tool(host, name, args),
    do: GenServer.call(host, {:call, :tool, name, args}, @call_timeout)

  @doc "Extension-registered slash commands as `[%{name, description}]` (waits for load)."
  @spec commands(pid()) :: [map()]
  def commands(host), do: GenServer.call(host, :commands, 15_000)

  @doc "Runs an extension slash command, returning `{:ok, text}`/`{:error, text}`."
  @spec call_command(pid(), String.t(), map()) :: {:ok, binary()} | {:error, binary()}
  def call_command(host, name, args),
    do: GenServer.call(host, {:call, :command, name, args}, @call_timeout)

  @doc "Fires a lifecycle event to the extensions (fire-and-forget hooks)."
  @spec fire_event(pid(), String.t(), map()) :: :ok
  def fire_event(host, event, payload), do: GenServer.cast(host, {:event, event, payload})

  @doc "Re-discovers and hot-reloads the extension dirs (self-evolution)."
  @spec reload(pid()) :: [ToolSpec.t()]
  def reload(host), do: GenServer.call(host, :reload, 15_000)

  @doc "Global + project extension directories, in load order (project wins)."
  @spec extension_dirs(String.t()) :: [String.t()]
  def extension_dirs(cwd) do
    [Path.expand("~/.longpi/extensions"), Path.join(cwd, ".longpi/extensions")]
  end

  # Server

  @impl true
  def init(cwd) do
    {:ok, bun} = find_bun()
    script = Path.join(:code.priv_dir(:longpi), "ext_host/host.ts")

    port =
      Port.open(
        {:spawn_executable, bun},
        [{:args, [script]}, :binary, {:packet, 4}, :exit_status, {:cd, cwd}]
      )

    send_frame(port, %{type: "load", cwd: cwd, dirs: extension_dirs(cwd)})

    {:ok,
     %{
       port: port,
       cwd: cwd,
       tools: [],
       commands: [],
       ready?: false,
       waiters: [],
       pending: %{},
       next_id: 0
     }}
  end

  @impl true
  def handle_call(:tool_specs, _from, %{ready?: true} = state),
    do: {:reply, build_specs(state), state}

  def handle_call(:commands, _from, %{ready?: true} = state), do: {:reply, state.commands, state}

  def handle_call(kind, from, state) when kind in [:tool_specs, :commands] do
    {:noreply, %{state | waiters: [{from, kind} | state.waiters]}}
  end

  def handle_call(:reload, from, state) do
    send_frame(state.port, %{type: "reload"})
    {:noreply, %{state | ready?: false, waiters: [{from, :tool_specs} | state.waiters]}}
  end

  def handle_call({:call, :tool, name, args}, from, state) do
    id = state.next_id
    send_frame(state.port, %{type: "call", id: id, tool: name, args: args})
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  def handle_call({:call, :command, name, args}, from, state) do
    id = state.next_id
    send_frame(state.port, %{type: "command", id: id, name: name, args: args})
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_cast({:event, event, payload}, state) do
    if state.ready?, do: send_frame(state.port, %{type: "event", event: event, payload: payload})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "ready", "tools" => tools} = msg} ->
        log_errors(state.cwd, msg["errors"])
        state = %{state | tools: tools, commands: msg["commands"] || [], ready?: true}
        reply_waiters(state)
        {:noreply, %{state | waiters: []}}

      {:ok, %{"type" => "result", "id" => id, "ok" => ok, "content" => content}} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, if(ok, do: {:ok, content}, else: {:error, content}))
        {:noreply, %{state | pending: pending}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("longpi extension host exited (status #{status})")
    Enum.each(Map.values(state.pending), &GenServer.reply(&1, {:error, "extension host exited"}))
    Enum.each(state.waiters, fn {from, _kind} -> GenServer.reply(from, []) end)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Each reported tool becomes a spec whose run forwards to this host process.
  defp build_specs(state) do
    host = self()

    Enum.map(state.tools, fn %{"name" => name, "description" => desc} = tool ->
      %ToolSpec{
        name: name,
        description: desc,
        schema: tool["parameters"] || %{"type" => "object"},
        run: fn args, _ctx -> call_tool(host, name, args) end,
        source: :extension
      }
    end)
  end

  defp reply_waiters(state) do
    Enum.each(state.waiters, fn
      {from, :commands} -> GenServer.reply(from, state.commands)
      {from, _} -> GenServer.reply(from, build_specs(state))
    end)
  end

  defp send_frame(port, message), do: Port.command(port, Jason.encode!(message))

  defp log_errors(_cwd, nil), do: :ok
  defp log_errors(_cwd, []), do: :ok

  defp log_errors(cwd, errors) do
    for %{"file" => file, "error" => error} <- errors do
      Logger.warning("extension failed to load (#{cwd}): #{file}\n#{error}")
    end
  end

  defp find_bun do
    case System.find_executable("bun") || Application.get_env(:longpi, :bun_path) do
      path when is_binary(path) -> {:ok, path}
      _ -> :error
    end
  end
end
