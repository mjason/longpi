defmodule Longpi.Extensions.Host do
  @moduledoc """
  Manages one WebAssembly extension host for a session's working directory.

  The Elixir brain owns the agent loop; a sandboxed QuickJS guest (see
  `priv/wasm/harness.js`, run by the self-maintained wasmtime NIF in
  `Longpi.Wasm`) owns extension module loading and execution. Framing is a
  4-byte length prefix carrying JSON both ways — the same protocol the old
  Bun host spoke, so extensions are source-compatible (modern JS; TS type
  syntax is not parsed by QuickJS).

  The guest has no capabilities beyond stdio and read-only extension dirs.
  Real-world effects are capability frames this process services:

    * `http` — fetch() shim; executed with Req, so timeouts/caps/secrets are
      enforced (and auditable) on the Elixir side
    * `run`  — `longpi.run(cmd, args)`; runs a system program (python, go, …)

  Reload = kill the instance and boot a fresh one: instances start in
  milliseconds and stale module caches can't exist.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Longpi.Agent.ToolSpec

  @call_timeout 120_000
  # A tool call stuck longer than this gets the guest epoch-interrupted.
  @watchdog_timeout 150_000
  @run_timeout 60_000
  @http_body_cap 5_000_000

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

  @doc "Re-discovers extensions by rebooting the guest (fresh instance)."
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

    case boot_instance(cwd) do
      {:ok, instance, wasm_id, staging_root} ->
        {:ok,
         %{
           instance: instance,
           wasm_id: wasm_id,
           staging_root: staging_root,
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
    cleanup_staging(state[:staging_root])
    :ok
  end

  # Boots a fresh QuickJS guest and sends it the load frame. The harness dir
  # is preopened at /host; each existing extension dir at /ext0, /ext1, …
  defp boot_instance(cwd) do
    wasm_id = System.unique_integer([:positive])
    harness_dir = Path.join(:code.priv_dir(:longpi), "wasm")
    staging_root = Path.join(System.tmp_dir!(), "longpi-ext-#{wasm_id}")

    # Extensions are authored in TS but the guest runs plain JS, so we stage a
    # type-stripped copy of each extension dir into a temp tree and preopen
    # THOSE (read-only) instead of the user's originals. The guest's discovery
    # is unchanged — it just imports the staged `.js`.
    {staged_preopens, guest_dirs} =
      cwd
      |> extension_dirs()
      |> Enum.filter(&File.dir?/1)
      |> Enum.with_index()
      |> Enum.map(fn {src_dir, index} ->
        guest = "/ext#{index}"
        stage_dir = Path.join(staging_root, "ext#{index}")
        stage_extension_dir(src_dir, stage_dir)
        {{stage_dir, guest}, guest}
      end)
      |> Enum.unzip()

    preopens = [{harness_dir, "/host"} | staged_preopens]

    case Longpi.Wasm.Native.start(
           Path.join(harness_dir, "qjs-wasi.wasm"),
           preopens,
           ["qjs", "/host/harness.js"],
           wasm_id
         ) do
      instance when is_reference(instance) ->
        Longpi.Wasm.send_json(instance, %{
          type: "load",
          cwd: cwd,
          dirs: guest_dirs,
          env: Longpi.Extensions.secret_env()
        })

        {:ok, instance, wasm_id, staging_root}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # Mirrors one extension dir into `dst` as plain JS. Matches the guest's
  # discovery (one level deep): top-level `*.ts`/`*.js`/`*.mjs`, and
  # `<subdir>/index.{ts,js}`. `.ts` files are type-stripped and written as
  # `.js`; `.js`/`.mjs` are copied verbatim. A file whose TS fails to strip is
  # copied as-is so the guest surfaces the real syntax error.
  defp stage_extension_dir(src_dir, dst_dir) do
    File.mkdir_p!(dst_dir)

    case File.ls(src_dir) do
      {:ok, entries} ->
        for entry <- entries do
          path = Path.join(src_dir, entry)

          cond do
            File.regular?(path) and String.ends_with?(entry, [".ts", ".js", ".mjs"]) ->
              stage_file(path, Path.join(dst_dir, staged_name(entry)))

            File.dir?(path) ->
              Enum.find_value(["index.ts", "index.js"], fn index ->
                index_path = Path.join(path, index)

                if File.regular?(index_path) do
                  sub = Path.join(dst_dir, entry)
                  File.mkdir_p!(sub)
                  stage_file(index_path, Path.join(sub, staged_name(index)))
                end
              end)

            true ->
              :ok
          end
        end

      {:error, _} ->
        :ok
    end
  end

  # `.ts` becomes `.js` (post-strip); other extensions keep their name.
  defp staged_name(entry) do
    if String.ends_with?(entry, ".ts"), do: Path.rootname(entry) <> ".js", else: entry
  end

  defp stage_file(src_path, dst_path) do
    source = File.read!(src_path)

    staged =
      if String.ends_with?(src_path, ".ts") do
        case Longpi.Wasm.strip_ts(source) do
          {:ok, js} ->
            js

          {:error, message} ->
            Logger.warning("extension type-strip failed (#{src_path}): #{message}")
            source
        end
      else
        source
      end

    File.write!(dst_path, staged)
  end

  defp cleanup_staging(nil), do: :ok
  defp cleanup_staging(staging_root), do: File.rm_rf(staging_root)

  @impl true
  def handle_call(:tool_specs, _from, %{ready?: true} = state),
    do: {:reply, build_specs(state), state}

  def handle_call(:commands, _from, %{ready?: true} = state), do: {:reply, state.commands, state}

  def handle_call(kind, from, state) when kind in [:tool_specs, :commands] do
    {:noreply, %{state | waiters: [{from, kind} | state.waiters]}}
  end

  def handle_call(:reload, from, state) do
    # Fresh guest: newly written/edited extension files and newly saved
    # secrets all take effect, and no stale module cache can survive.
    Longpi.Wasm.close_stdin(state.instance)
    Longpi.Wasm.interrupt(state.instance)
    cleanup_staging(state.staging_root)

    case boot_instance(state.cwd) do
      {:ok, instance, wasm_id, staging_root} ->
        state = %{
          state
          | instance: instance,
            wasm_id: wasm_id,
            staging_root: staging_root,
            ready?: false,
            waiters: [{from, :tool_specs} | state.waiters]
        }

        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_call({:call, kind, name, args}, from, state) do
    id = state.next_id

    frame =
      case kind do
        # Secrets ride along on every call — a key added/changed in the UI
        # takes effect on the next tool call with no reload.
        :tool ->
          %{type: "call", id: id, tool: name, args: args, env: Longpi.Extensions.secret_env()}

        :command ->
          %{type: "command", id: id, name: name, args: args}
      end

    Longpi.Wasm.send_json(state.instance, frame)
    watchdog = state.watchdog || Process.send_after(self(), :watchdog, @watchdog_timeout)

    {:noreply,
     %{state | next_id: id + 1, pending: Map.put(state.pending, id, from), watchdog: watchdog}}
  end

  @impl true
  def handle_cast({:event, event, payload}, state) do
    if state.ready? do
      Longpi.Wasm.send_json(state.instance, %{type: "event", event: event, payload: payload})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:wasm_frame, wasm_id, data}, %{wasm_id: wasm_id} = state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "ready", "tools" => tools} = msg} ->
        log_errors(state.cwd, msg["errors"])
        state = %{state | tools: tools, commands: msg["commands"] || [], ready?: true}
        reply_waiters(state)
        {:noreply, %{state | waiters: []}}

      {:ok, %{"type" => "result", "id" => id, "ok" => ok, "content" => content}} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, if(ok, do: {:ok, content}, else: {:error, content}))
        state = cancel_watchdog(%{state | pending: pending})
        {:noreply, state}

      {:ok, %{"type" => "http", "id" => id, "request" => request}} ->
        serve_http(self(), state.instance, id, request)
        {:noreply, state}

      {:ok, %{"type" => "run", "id" => id} = msg} ->
        serve_run(self(), state.instance, id, msg, state.cwd)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:wasm_frame, _stale_id, _data}, state), do: {:noreply, state}

  def handle_info({:wasm_exit, wasm_id, reason}, %{wasm_id: wasm_id} = state) do
    Logger.warning("longpi wasm extension host exited (#{inspect(reason)})")
    Enum.each(Map.values(state.pending), &GenServer.reply(&1, {:error, "extension host exited"}))
    Enum.each(state.waiters, fn {from, _kind} -> GenServer.reply(from, []) end)
    {:stop, :normal, state}
  end

  def handle_info({:wasm_exit, _stale_id, _reason}, state), do: {:noreply, state}

  # A call outlived the watchdog: the guest is likely stuck in a hot loop.
  # Epoch-interrupt traps it; the resulting :wasm_exit fails pending callers.
  def handle_info(:watchdog, %{pending: pending} = state) when map_size(pending) > 0 do
    Logger.warning("extension call watchdog fired — interrupting the wasm guest")
    Longpi.Wasm.interrupt(state.instance)
    {:noreply, %{state | watchdog: nil}}
  end

  def handle_info(:watchdog, state), do: {:noreply, %{state | watchdog: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Capability brokering ────────────────────────────────────────────

  # fetch() shim backend: Req with hard limits; the guest gets text bodies
  # as-is and binary bodies base64-tagged.
  defp serve_http(host, instance, id, request) do
    Task.start(fn ->
      response =
        try do
          options =
            [
              method: parse_method(request["method"]),
              url: request["url"],
              headers: Map.to_list(request["headers"] || %{}),
              body: request["body"],
              receive_timeout: 30_000,
              retry: false
            ] ++ Application.get_env(:longpi, :ext_http_options, [])

          case Req.request(options) do
            {:ok, %Req.Response{} = res} ->
              body = clamp_body(res.body)

              base = %{
                type: "http_result",
                id: id,
                status: res.status,
                headers: Map.new(res.headers, fn {k, v} -> {k, Enum.join(List.wrap(v), ", ")} end)
              }

              if is_binary(body) and not String.valid?(body) do
                Map.merge(base, %{body: Base.encode64(body), bodyEncoding: "base64"})
              else
                Map.put(base, :body, to_text_body(body))
              end

            {:error, error} ->
              %{type: "http_result", id: id, error: Exception.message(error)}
          end
        rescue
          e -> %{type: "http_result", id: id, error: Exception.message(e)}
        end

      if Process.alive?(host), do: Longpi.Wasm.send_json(instance, response)
    end)
  end

  defp parse_method(method) when is_binary(method),
    do: method |> String.downcase() |> String.to_existing_atom()

  defp parse_method(_), do: :get

  defp clamp_body(body) when is_binary(body) and byte_size(body) > @http_body_cap,
    do: binary_part(body, 0, @http_body_cap)

  defp clamp_body(body), do: body

  # Req may have decoded JSON into a map — hand the guest the raw text back.
  defp to_text_body(body) when is_binary(body), do: body
  defp to_text_body(body), do: Jason.encode!(body)

  # longpi.run() backend: run a system program with a timeout, from the
  # workspace directory.
  defp serve_run(host, instance, id, msg, cwd) do
    Task.start(fn ->
      response =
        try do
          cmd = msg["cmd"]
          args = Enum.map(msg["args"] || [], &to_string/1)
          dir = (msg["opts"] || %{})["cwd"] || cwd

          case System.find_executable(cmd) do
            nil ->
              %{type: "run_result", id: id, status: 127, stdout: "", stderr: "#{cmd}: not found"}

            path ->
              task =
                Task.async(fn ->
                  System.cmd(path, args, cd: dir, stderr_to_stdout: true, env: [])
                end)

              case Task.yield(task, @run_timeout) || Task.shutdown(task, :brutal_kill) do
                {:ok, {output, status}} ->
                  %{type: "run_result", id: id, status: status, stdout: output, stderr: ""}

                _ ->
                  %{type: "run_result", id: id, status: 124, stdout: "", stderr: "timed out"}
              end
          end
        rescue
          e -> %{type: "run_result", id: id, status: 1, stdout: "", stderr: Exception.message(e)}
        end

      if Process.alive?(host), do: Longpi.Wasm.send_json(instance, response)
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

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

  defp log_errors(_cwd, nil), do: :ok
  defp log_errors(_cwd, []), do: :ok

  defp log_errors(cwd, errors) do
    for %{"file" => file, "error" => error} <- errors do
      Logger.warning("extension failed to load (#{cwd}): #{file}\n#{error}")
    end
  end
end
