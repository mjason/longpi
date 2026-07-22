defmodule Longpi.Js.Native do
  @moduledoc false
  use Rustler, otp_app: :longpi, crate: "longpi_js"

  def start(_id), do: :erlang.nif_error(:nif_not_loaded)
  def load(_instance, _extensions, _env), do: :erlang.nif_error(:nif_not_loaded)
  def call_tool(_instance, _call_id, _name, _args_json, _env), do: :erlang.nif_error(:nif_not_loaded)
  def call_command(_instance, _call_id, _name, _arg), do: :erlang.nif_error(:nif_not_loaded)
  def fire_event(_instance, _event, _payload_json), do: :erlang.nif_error(:nif_not_loaded)
  def interrupt(_instance), do: :erlang.nif_error(:nif_not_loaded)
  def stop(_instance), do: :erlang.nif_error(:nif_not_loaded)
  def capability_reply(_instance, _req_id, _result), do: :erlang.nif_error(:nif_not_loaded)
  def strip_ts_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
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
  def call_tool(instance, call_id, name, args, env) do
    Longpi.Js.Native.call_tool(instance, call_id, name, Jason.encode!(args), Map.to_list(Map.new(env)))
  end

  @doc "Runs a registered slash command."
  def call_command(instance, call_id, name, arg) do
    Longpi.Js.Native.call_command(instance, call_id, name, arg)
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
    result =
      case Jason.decode(payload) do
        {:ok, %{"cmd" => cmd} = req} when is_binary(cmd) ->
          run_program(cmd, req["args"] || [], (req["opts"] || %{})["cwd"] || cwd)

        _ ->
          %{status: 1, stdout: "", stderr: "invalid run request"}
      end

    Longpi.Js.Native.capability_reply(instance, req_id, Jason.encode!(result))
  end

  @run_timeout 60_000

  defp run_program(cmd, args, dir) do
    args = Enum.map(args, &to_string/1)

    case System.find_executable(cmd) do
      nil ->
        %{status: 127, stdout: "", stderr: "#{cmd}: not found"}

      path ->
        task =
          Task.async(fn -> System.cmd(path, args, cd: dir, stderr_to_stdout: false, env: []) end)

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
end
