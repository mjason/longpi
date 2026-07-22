defmodule Longpi.Wasm.Native do
  @moduledoc false
  use Rustler, otp_app: :longpi, crate: "longpi_wasm"

  def start(_wasm_path, _preopen_dir, _argv, _id), do: :erlang.nif_error(:nif_not_loaded)
  def send_frame(_instance, _payload), do: :erlang.nif_error(:nif_not_loaded)
  def interrupt(_instance), do: :erlang.nif_error(:nif_not_loaded)
  def close_stdin(_instance), do: :erlang.nif_error(:nif_not_loaded)
  def instance_id(_instance), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Longpi.Wasm do
  @moduledoc """
  Self-maintained minimal wasmtime embedding (see native/longpi_wasm) used by
  the Wasm extension host: runs a WASI-p1 QuickJS guest whose stdio speaks the
  same 4-byte-BE + JSON frame protocol as the Bun host.

  The calling process receives:

    * `{:wasm_frame, id, binary}` — one frame from the guest
    * `{:wasm_exit, id, :normal | :trap}` — the guest finished/died

  Guests are fully sandboxed: no filesystem (beyond the read-only preopen for
  the interpreter's script), no network, no clock capabilities beyond WASI
  defaults. Every real-world capability (HTTP, running system programs) is a
  frame the Elixir side services — Elixir is the capability broker.
  """

  @doc """
  Starts a QuickJS guest evaluating `script_path` (inside `preopen_dir`,
  which is mounted read-only at `/`). `id` tags this instance's messages.
  """
  def start_quickjs(preopen_dir, script_rel_path, id) do
    instance =
      Longpi.Wasm.Native.start(
        qjs_wasm_path(),
        preopen_dir,
        ["qjs", "/" <> script_rel_path],
        id
      )

    {:ok, instance}
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defdelegate send_frame(instance, payload), to: Longpi.Wasm.Native
  defdelegate interrupt(instance), to: Longpi.Wasm.Native
  defdelegate close_stdin(instance), to: Longpi.Wasm.Native

  @doc "Sends a map as a JSON frame."
  def send_json(instance, map), do: send_frame(instance, Jason.encode!(map))

  defp qjs_wasm_path do
    Path.join(:code.priv_dir(:longpi), "wasm/qjs-wasi.wasm")
  end
end
