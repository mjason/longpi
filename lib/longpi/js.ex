defmodule Longpi.Js.Native do
  @moduledoc false
  use Rustler, otp_app: :longpi, crate: "longpi_js"

  def start(_id), do: :erlang.nif_error(:nif_not_loaded)
  def load(_instance, _extensions, _env), do: :erlang.nif_error(:nif_not_loaded)

  def call_tool(_instance, _call_id, _name, _args_json, _cwd, _env),
    do: :erlang.nif_error(:nif_not_loaded)

  def call_command(_instance, _call_id, _name, _args_json, _cwd, _env),
    do: :erlang.nif_error(:nif_not_loaded)
  def fire_event(_instance, _event, _payload_json), do: :erlang.nif_error(:nif_not_loaded)
  def interrupt(_instance), do: :erlang.nif_error(:nif_not_loaded)
  def stop(_instance), do: :erlang.nif_error(:nif_not_loaded)
  def capability_reply(_instance, _req_id, _result), do: :erlang.nif_error(:nif_not_loaded)
  def strip_ts_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  def decode_bytes(_data), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Longpi.Js do
  @moduledoc """
  Native QuickJS extension runtime (via the self-maintained `longpi_js` NIF,
  rquickjs-backed). Extensions run as plain JS/TS in an in-process QuickJS;
  capabilities (fetch, run, crypto, console) are Rust host functions, so there
  is no wasm sandbox, no frame protocol, and no stdio bridge.

  Each instance owns a dedicated OS thread. The owning process receives:

    * `{:js_loaded, id, tools, commands, errors}` — after `load/3`
      (`tools` = `[{name, description, parameters_json}]`,
       `commands` = `[{name, description}]`, `errors` = `[{name, message}]`)
    * `{:js_result, id, call_id, ok?, content}` — after a tool/command call
  """

  @doc "Starts an instance owned by the calling process; `id` tags its messages."
  def start(id) when is_integer(id) do
    {:ok, Longpi.Js.Native.start(id)}
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Loads extensions: `[{name, source}]` (TS is stripped) with `env` secrets."
  def load(instance, extensions, env) do
    Longpi.Js.Native.load(instance, extensions, Map.to_list(Map.new(env)))
  end

  @doc "Runs a registered tool; result arrives as `{:js_result, id, call_id, ...}`."
  def call_tool(instance, call_id, name, args, cwd, env) do
    Longpi.Js.Native.call_tool(
      instance,
      call_id,
      name,
      Jason.encode!(args),
      cwd,
      Map.to_list(Map.new(env))
    )
  end

  @doc "Runs a registered slash command; `arg` is the bare text after the name."
  def call_command(instance, call_id, name, arg, cwd, env) do
    Longpi.Js.Native.call_command(
      instance,
      call_id,
      name,
      Jason.encode!(arg),
      cwd,
      Map.to_list(Map.new(env))
    )
  end

  @doc "Fires a lifecycle event to `on(...)` handlers (fire-and-forget)."
  def fire_event(instance, event, payload) do
    Longpi.Js.Native.fire_event(instance, event, Jason.encode!(payload))
  end

  @doc """
  Answers a `{:js_capability, id, req_id, "run", payload}` request: runs the
  program (a NIF can't spawn OS processes safely, so `longpi.run` is brokered
  here) and replies. `payload` is `{"cmd", "args", "opts"}` JSON.
  """
  def service_run(instance, req_id, payload, cwd) do
    # Always reply, even on a crash — otherwise the JS `await longpi.run(...)`
    # hangs the whole instance until the Rust broker timeout (~120s).
    result =
      try do
        case Jason.decode(payload) do
          {:ok, %{"cmd" => cmd} = req} when is_binary(cmd) ->
            run_program(cmd, req["args"] || [], (req["opts"] || %{})["cwd"] || cwd)

          _ ->
            %{status: 1, stdout: "", stderr: "invalid run request"}
        end
      rescue
        e -> %{status: 1, stdout: "", stderr: "run failed: #{Exception.message(e)}"}
      catch
        kind, reason -> %{status: 1, stdout: "", stderr: "run failed: #{inspect({kind, reason})}"}
      end

    Longpi.Js.Native.capability_reply(instance, req_id, Jason.encode!(result))
  end

  @run_timeout 60_000

  # stderr is merged into stdout (System.cmd can't split it without a Port);
  # the child inherits the server's environment so PATH/HOME resolve.
  defp run_program(cmd, args, dir) do
    args = Enum.map(args, &to_string/1)

    cond do
      not (is_binary(dir) and File.dir?(dir)) ->
        %{status: 1, stdout: "", stderr: "working directory does not exist: #{inspect(dir)}"}

      is_nil(System.find_executable(cmd)) ->
        %{status: 127, stdout: "", stderr: "#{cmd}: not found"}

      true ->
        path = System.find_executable(cmd)

        task =
          Task.async(fn -> System.cmd(path, args, cd: dir, stderr_to_stdout: true) end)

        case Task.yield(task, @run_timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, status}} -> %{status: status, stdout: output, stderr: ""}
          _ -> %{status: 124, stdout: "", stderr: "timed out"}
        end
    end
  end

  @doc "Traps a runaway script (interrupt flag)."
  defdelegate interrupt(instance), to: Longpi.Js.Native

  @doc "Shuts the instance's runtime down."
  defdelegate stop(instance), to: Longpi.Js.Native

  @doc "Strips TypeScript types to plain JS. `{:ok, js}` / `{:error, message}`."
  def strip_ts(source) when is_binary(source) do
    Longpi.Js.Native.strip_ts_nif(source)
  rescue
    e in ErlangError -> {:error, inspect(e.original)}
  end

  @doc """
  Decodes raw bytes to UTF-8: passes valid UTF-8 through, otherwise detects the
  encoding (GBK/Big5/Shift-JIS/EUC-KR/windows-*/…) and decodes. Falls back to a
  lossy scrub if the NIF isn't available.
  """
  def decode_bytes(data) when is_binary(data) do
    Longpi.Js.Native.decode_bytes(data)
  rescue
    _ -> String.replace_invalid(data)
  end
end
