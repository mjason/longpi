defmodule Longpi.Extensions.Host do
  @moduledoc """
  Manages one native QuickJS extension runtime (via `Longpi.Js`, rquickjs) for
  a session's working directory.

  The Elixir brain owns the agent loop; extensions run as plain JS/TS in an
  in-process QuickJS whose capabilities are Rust host functions — `fetch`
  (reqwest), `crypto`, `console` — with no wasm sandbox, frame protocol, or
  stdio bridge. `longpi.run` (spawning an OS process) is the one capability a
  NIF can't do safely, so it is brokered back here to `System.cmd`.

  TypeScript is stripped (oxc) before running, so extensions may be authored in
  JS or TS. Secrets are injected as `process.env` on every call.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Longpi.Agent.ToolSpec

  @call_timeout 120_000
  # A tool call stuck past this gets the runtime interrupted (runaway guard).
  @watchdog_timeout 150_000

  # Client

  @doc "Starts a host for `cwd`, or `:none` when the workspace has no extensions."
  @spec start_for(String.t()) :: {:ok, pid()} | :none
  def start_for(cwd) do
    with true <- Longpi.Extensions.any_for?(cwd),
         {:ok, pid} <- GenServer.start_link(__MODULE__, cwd) do
      {:ok, pid}
    else
      _ -> :none
    end
  end

  @doc "Tool specs for every extension-registered tool (waits for load)."
  @spec tool_specs(pid()) :: [ToolSpec.t()]
  def tool_specs(host), do: GenServer.call(host, :tool_specs, 15_000)

  @doc "Runs an extension tool, returning `{:ok, text}`/`{:error, text}`."
  @spec call_tool(pid(), String.t(), map()) :: {:ok, binary()} | {:error, binary()}
  def call_tool(host, name, args),
    do: GenServer.call(host, {:call, :tool, name, args}, @call_timeout)

  @doc "Extension-registered slash commands as `[%{name, description}]` (waits for load)."
  @spec commands(pid()) :: [map()]
  def commands(host), do: GenServer.call(host, :commands, 15_000)

  @doc "Runs an extension slash command."
  @spec call_command(pid(), String.t(), map()) :: {:ok, binary()} | {:error, binary()}
  def call_command(host, name, args),
    do: GenServer.call(host, {:call, :command, name, args}, @call_timeout)

  @doc "Fires a lifecycle event to the extensions (fire-and-forget hooks)."
  @spec fire_event(pid(), String.t(), map()) :: :ok
  def fire_event(host, event, payload), do: GenServer.cast(host, {:event, event, payload})

  @doc "Re-discovers and reloads the extensions in place (same runtime)."
  @spec reload(pid()) :: [ToolSpec.t()]
  def reload(host), do: GenServer.call(host, :reload, 15_000)

  @doc "Global + project extension directories, in load order (project wins)."
  @spec extension_dirs(String.t()) :: [String.t()]
  def extension_dirs(cwd) do
    [Longpi.Extensions.global_dir(), Path.join(cwd, ".longpi/extensions")]
  end

  # Server

  @impl true
  def init(cwd) do
    Process.flag(:trap_exit, true)
    id = System.unique_integer([:positive])

    case Longpi.Js.start(id) do
      {:ok, instance} ->
        Longpi.Js.load(instance, collect_extensions(cwd), Longpi.Extensions.secret_env())

        {:ok,
         %{
           instance: instance,
           id: id,
           cwd: cwd,
           tools: [],
           commands: [],
           ready?: false,
           waiters: [],
           pending: %{},
           next_id: 0,
           watchdog: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state[:instance], do: Longpi.Js.stop(state.instance)
    :ok
  end

  # ── Extension discovery ──────────────────────────────────────────────
  # Reads each extension into `{display_name, source}`; the runtime strips TS
  # and evaluates. One level deep: top-level *.ts/*.js/*.mjs and
  # subdir/index.{ts,js}, global dir first so project extensions win on name.

  defp collect_extensions(cwd) do
    cwd
    |> extension_dirs()
    |> Enum.flat_map(&collect_dir/1)
  end

  defp collect_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(Enum.sort(entries), fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.regular?(path) and String.ends_with?(entry, [".ts", ".js", ".mjs"]) ->
              [{path, File.read!(path)}]

            File.dir?(path) ->
              Enum.find_value(["index.ts", "index.js"], [], fn index ->
                index_path = Path.join(path, index)
                if File.regular?(index_path), do: [{index_path, File.read!(index_path)}]
              end)

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # ── Waited queries ───────────────────────────────────────────────────

  @impl true
  def handle_call(:tool_specs, _from, %{ready?: true} = state),
    do: {:reply, build_specs(state), state}

  def handle_call(:commands, _from, %{ready?: true} = state), do: {:reply, state.commands, state}

  def handle_call(kind, from, state) when kind in [:tool_specs, :commands] do
    {:noreply, %{state | waiters: [{from, kind} | state.waiters]}}
  end

  def handle_call(:reload, from, state) do
    # Re-read the dirs and reload in place; the runtime clears its registry on
    # load, so this picks up new/edited files and refreshed secrets.
    Longpi.Js.load(state.instance, collect_extensions(state.cwd), Longpi.Extensions.secret_env())
    {:noreply, %{state | ready?: false, waiters: [{from, :tool_specs} | state.waiters]}}
  end

  def handle_call({:call, kind, name, args}, from, state) do
    id = state.next_id

    case kind do
      :tool ->
        # Secrets ride along on every call — a key added/changed in the UI
        # takes effect on the next tool call with no reload.
        Longpi.Js.call_tool(state.instance, id, name, args, Longpi.Extensions.secret_env())

      :command ->
        Longpi.Js.call_command(state.instance, id, name, command_arg(args))
    end

    watchdog = state.watchdog || Process.send_after(self(), :watchdog, @watchdog_timeout)
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from), watchdog: watchdog}}
  end

  # Slash-command args arrive as a bare string ("/cmd the rest").
  defp command_arg(arg) when is_binary(arg), do: arg
  defp command_arg(_), do: ""

  @impl true
  def handle_cast({:event, event, payload}, state) do
    if state.ready?, do: Longpi.Js.fire_event(state.instance, event, payload)
    {:noreply, state}
  end

  # ── Runtime messages ─────────────────────────────────────────────────

  @impl true
  def handle_info({:js_loaded, id, tools, commands, errors}, %{id: id} = state) do
    log_errors(state.cwd, errors)

    tools = for {name, description, params_json} <- tools, do: %{name: name, description: description, parameters_json: params_json}
    commands = for {name, description} <- commands, do: %{"name" => name, "description" => description}

    state = %{state | tools: tools, commands: commands, ready?: true}
    reply_waiters(state)
    {:noreply, %{state | waiters: []}}
  end

  def handle_info({:js_result, id, call_id, ok, content}, %{id: id} = state) do
    {from, pending} = Map.pop(state.pending, call_id)
    if from, do: GenServer.reply(from, if(ok, do: {:ok, content}, else: {:error, content}))
    {:noreply, cancel_watchdog(%{state | pending: pending})}
  end

  # `longpi.run` brokered from the runtime: run the program and reply. Done in a
  # task so a slow command doesn't block the host's mailbox.
  def handle_info({:js_capability, id, req_id, "run", payload}, %{id: id} = state) do
    instance = state.instance
    cwd = state.cwd
    Task.start(fn -> Longpi.Js.service_run(instance, req_id, payload, cwd) end)
    {:noreply, state}
  end

  # Stale-id messages from a previous runtime (after a crash/restart): ignore.
  def handle_info({tag, _id, _, _, _}, state) when tag in [:js_loaded, :js_result, :js_capability],
    do: {:noreply, state}

  # A tool call outran the watchdog — likely a hot loop. Interrupt the runtime.
  def handle_info(:watchdog, %{pending: pending} = state) when map_size(pending) > 0 do
    Logger.warning("extension call watchdog fired — interrupting the JS runtime")
    Longpi.Js.interrupt(state.instance)
    {:noreply, %{state | watchdog: nil}}
  end

  def handle_info(:watchdog, state), do: {:noreply, %{state | watchdog: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ──────────────────────────────────────────────────────────

  defp cancel_watchdog(%{watchdog: nil} = state), do: state

  defp cancel_watchdog(state) do
    if map_size(state.pending) == 0 do
      Process.cancel_timer(state.watchdog)
      %{state | watchdog: nil}
    else
      state
    end
  end

  # Each reported tool becomes a spec whose run forwards to this host process.
  defp build_specs(state) do
    host = self()

    Enum.map(state.tools, fn %{name: name, description: desc, parameters_json: params_json} ->
      %ToolSpec{
        name: name,
        description: desc,
        schema: decode_params(params_json),
        run: fn args, _ctx -> call_tool(host, name, args) end,
        source: :extension
      }
    end)
  end

  defp decode_params(json) do
    case Jason.decode(json) do
      {:ok, %{} = schema} -> schema
      _ -> %{"type" => "object"}
    end
  end

  defp reply_waiters(state) do
    Enum.each(state.waiters, fn
      {from, :commands} -> GenServer.reply(from, state.commands)
      {from, _} -> GenServer.reply(from, build_specs(state))
    end)
  end

  defp log_errors(_cwd, []), do: :ok

  defp log_errors(cwd, errors) do
    for {file, message} <- errors do
      Logger.warning("extension failed to load (#{cwd}): #{file}\n#{message}")
    end
  end
end
