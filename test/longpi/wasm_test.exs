defmodule Longpi.WasmTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # Minimal harness speaking the frame protocol (4-byte BE length + JSON).
  # The real extension harness builds on exactly these primitives.
  @harness """
  import * as os from "qjs:os";

  function utf8Encode(str) {
    const out = [];
    for (const ch of str) {
      let cp = ch.codePointAt(0);
      if (cp < 0x80) out.push(cp);
      else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
      else if (cp < 0x10000)
        out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      else
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    }
    return new Uint8Array(out);
  }

  function utf8Decode(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; ) {
      const b = bytes[i];
      let cp, extra;
      if (b < 0x80) { cp = b; extra = 0; }
      else if (b < 0xe0) { cp = b & 31; extra = 1; }
      else if (b < 0xf0) { cp = b & 15; extra = 2; }
      else { cp = b & 7; extra = 3; }
      for (let j = 1; j <= extra; j++) cp = (cp << 6) | (bytes[i + j] & 63);
      out += String.fromCodePoint(cp);
      i += extra + 1;
    }
    return out;
  }

  function readExact(fd, buf, off, len) {
    let got = 0;
    while (got < len) {
      const n = os.read(fd, buf, off + got, len - got);
      if (n <= 0) return got;
      got += n;
    }
    return got;
  }

  function readFrame() {
    const head = new ArrayBuffer(4);
    if (readExact(0, head, 0, 4) < 4) return null;
    const len = new DataView(head).getUint32(0, false);
    const body = new ArrayBuffer(len);
    if (readExact(0, body, 0, len) < len) return null;
    return JSON.parse(utf8Decode(new Uint8Array(body)));
  }

  function writeFrame(obj) {
    const body = utf8Encode(JSON.stringify(obj));
    const head = new ArrayBuffer(4);
    new DataView(head).setUint32(0, body.length, false);
    os.write(1, head, 0, 4);
    os.write(1, body.buffer, 0, body.length);
  }

  writeFrame({ type: "ready" });
  let msg;
  while ((msg = readFrame()) !== null) {
    if (msg.type === "ping") writeFrame({ type: "pong", echo: msg.value });
    else if (msg.type === "eval") {
      try { writeFrame({ type: "result", value: String(eval(msg.code)) }); }
      catch (e) { writeFrame({ type: "error", message: String(e) }); }
    }
    else if (msg.type === "spin") { for (;;) {} }
  }
  """

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "harness.js"), @harness)
    %{dir: dir}
  end

  test "guest speaks the frame protocol end to end", %{dir: dir} do
    {:ok, inst} = Longpi.Wasm.start_quickjs(dir, "harness.js", 1)

    assert_receive {:wasm_frame, 1, ready}, 15_000
    assert Jason.decode!(ready) == %{"type" => "ready"}

    Longpi.Wasm.send_json(inst, %{type: "ping", value: 7})
    assert_receive {:wasm_frame, 1, pong}, 5_000
    assert Jason.decode!(pong) == %{"type" => "pong", "echo" => 7}

    # Agent-written JS handed over as data — the self-extension path.
    Longpi.Wasm.send_json(inst, %{type: "eval", code: "[1,2,3].map(x=>x*x).join()"})
    assert_receive {:wasm_frame, 1, result}, 5_000
    assert %{"type" => "result", "value" => "1,4,9"} = Jason.decode!(result)

    # UTF-8 both ways.
    Longpi.Wasm.send_json(inst, %{type: "eval", code: ~s("你好" + "wasm")})
    assert_receive {:wasm_frame, 1, chinese}, 5_000
    assert %{"value" => "你好wasm"} = Jason.decode!(chinese)

    # EOF → clean exit.
    Longpi.Wasm.close_stdin(inst)
    assert_receive {:wasm_exit, 1, :normal}, 5_000
  end

  test "interrupt traps a runaway loop", %{dir: dir} do
    {:ok, inst} = Longpi.Wasm.start_quickjs(dir, "harness.js", 2)
    assert_receive {:wasm_frame, 2, _ready}, 15_000

    Longpi.Wasm.send_json(inst, %{type: "spin"})
    # Give it a moment to be genuinely stuck in the loop, then pull the plug.
    Process.sleep(200)
    Longpi.Wasm.interrupt(inst)
    assert_receive {:wasm_exit, 2, :trap}, 5_000
  end

  test "guest errors are reported, not fatal", %{dir: dir} do
    {:ok, inst} = Longpi.Wasm.start_quickjs(dir, "harness.js", 3)
    assert_receive {:wasm_frame, 3, _ready}, 15_000

    Longpi.Wasm.send_json(inst, %{type: "eval", code: "nope.nope()"})
    assert_receive {:wasm_frame, 3, err}, 5_000
    assert %{"type" => "error", "message" => message} = Jason.decode!(err)
    assert message =~ "ReferenceError"

    Longpi.Wasm.close_stdin(inst)
    assert_receive {:wasm_exit, 3, :normal}, 5_000
  end
end
