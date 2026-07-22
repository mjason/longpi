// QuickJS (WASI) extension host for longpi — replaces the Bun host.
//
// Same wire protocol as before: 4-byte big-endian length-prefixed JSON frames
// over stdin/stdout. stdout is protocol-only; console output goes to stderr.
//
//   Elixir -> host  {type:"load", cwd, dirs:[guest paths], env:{NAME:value}}
//                   {type:"call", id, tool, args, env}
//                   {type:"command", id, name, args}
//                   {type:"event", event, payload}
//   host -> Elixir  {type:"ready", tools, commands, errors}
//                   {type:"result", id, ok, content}
//
// Capability frames (host -> Elixir -> host): the guest has NO filesystem
// (beyond read-only extension dirs), no network, no processes. Everything
// real is brokered by Elixir:
//                   {type:"http", id, request}   <- fetch() shim
//                   {type:"http_result", id, ...}
//                   {type:"run", id, cmd, args}  <- longpi.run() escape hatch
//                   {type:"run_result", id, ...}
//
// Reload = the Elixir side kills this instance and starts a fresh one
// (instances boot in milliseconds), so this file only ever loads once.

import * as std from "qjs:std";
import * as os from "qjs:os";

// --- stdout hygiene: extension logs must not corrupt the frame stream ------

const errlog = (...args) =>
  std.err.puts(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ") + "\n");
globalThis.console = { log: errlog, info: errlog, warn: errlog, error: errlog, debug: errlog };
globalThis.print = errlog;

// --- UTF-8 codec (QuickJS has no TextEncoder/TextDecoder) ------------------

function utf8Encode(str) {
  const out = [];
  for (const ch of str) {
    let cp = ch.codePointAt(0);
    if (cp < 0x80) out.push(cp);
    else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
    else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
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

// --- framing ---------------------------------------------------------------

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

// --- capability brokering ---------------------------------------------------
// One in-flight capability request at a time (tool calls are serialized by
// the Elixir side, and QuickJS is single-threaded): send the request frame,
// then block-read until its response arrives. Unrelated frames that show up
// meanwhile are queued for the main loop.

const queuedFrames = [];
let capId = 0;

function capabilityCall(type, payload) {
  const id = "cap-" + ++capId;
  writeFrame({ type, id, ...payload });
  for (;;) {
    const msg = readFrame();
    if (msg === null) throw new Error("host connection closed");
    if (msg.id === id && msg.type === type + "_result") return msg;
    queuedFrames.push(msg);
  }
}

// fetch() shim: familiar surface, Elixir (Req) does the actual request and
// enforces timeouts/size caps. Bodies round-trip as UTF-8 text, or base64
// when binary.
function b64Decode(s) {
  const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const clean = s.replace(/[^A-Za-z0-9+/]/g, "");
  const out = [];
  for (let i = 0; i + 3 < clean.length || (i < clean.length && clean.length % 4 !== 1); i += 4) {
    const n =
      (table.indexOf(clean[i]) << 18) |
      (table.indexOf(clean[i + 1]) << 12) |
      ((table.indexOf(clean[i + 2]) & 63) << 6) |
      (table.indexOf(clean[i + 3]) & 63);
    out.push((n >> 16) & 255);
    if (clean[i + 2] !== undefined) out.push((n >> 8) & 255);
    if (clean[i + 3] !== undefined) out.push(n & 255);
  }
  return new Uint8Array(out);
}

globalThis.fetch = async function fetch(url, options = {}) {
  const res = capabilityCall("http", {
    request: {
      url: String(url),
      method: options.method || "GET",
      headers: options.headers || {},
      body: options.body ?? null,
    },
  });
  if (res.error) throw new Error("fetch failed: " + res.error);

  const bodyText =
    res.bodyEncoding === "base64" ? utf8Decode(b64Decode(res.body || "")) : res.body || "";
  const headers = res.headers || {};
  const lookup = {};
  for (const [k, v] of Object.entries(headers)) lookup[k.toLowerCase()] = v;

  return {
    ok: res.status >= 200 && res.status < 300,
    status: res.status,
    statusText: String(res.status),
    headers: { get: (k) => lookup[String(k).toLowerCase()] ?? null },
    text: async () => bodyText,
    json: async () => JSON.parse(bodyText),
  };
};

// Escape hatch: run a program on the host system (python, go binaries, …).
// Elixir executes it and applies its own limits.
function runProgram(cmd, args = [], opts = {}) {
  const res = capabilityCall("run", { cmd: String(cmd), args, opts });
  return { status: res.status, stdout: res.stdout ?? "", stderr: res.stderr ?? "" };
}

// process.env shim — populated from longpi's DB-stored secrets, injected by
// Elixir on load and refreshed on every call.
globalThis.process = { env: {} };

function applyEnv(env) {
  globalThis.process.env = env && typeof env === "object" ? { ...env } : {};
}

// --- extension discovery & loading ------------------------------------------

const TOOLS = new Map();
const COMMANDS = new Map();
const HANDLERS = new Map();
let CWD = "/";

const longpi = {
  registerTool(def) {
    TOOLS.set(def.name, def);
  },
  registerCommand(name, def) {
    COMMANDS.set(name, { name, ...def });
  },
  on(event, handler) {
    const list = HANDLERS.get(event) ?? [];
    list.push(handler);
    HANDLERS.set(event, list);
  },
  run: runProgram,
};

// One level deep in an extensions dir: *.ts/*.js files or subdir/index.ts|js.
// (npm package manifests were a Bun-host feature and are gone with it.)
function discover(dir) {
  const [entries, err] = os.readdir(dir);
  if (err !== 0) return [];
  const out = [];
  for (const name of entries.sort()) {
    if (name === "." || name === "..") continue;
    const path = dir + "/" + name;
    const [st, serr] = os.stat(path);
    if (serr !== 0) continue;
    if ((st.mode & os.S_IFMT) === os.S_IFREG && /\.(ts|js|mjs)$/.test(name)) {
      out.push(path);
    } else if ((st.mode & os.S_IFMT) === os.S_IFDIR) {
      for (const index of ["index.ts", "index.js"]) {
        const [ist, ierr] = os.stat(path + "/" + index);
        if (ierr === 0 && (ist.mode & os.S_IFMT) === os.S_IFREG) {
          out.push(path + "/" + index);
          break;
        }
      }
    }
  }
  return out;
}

async function loadAll(dirs) {
  const errors = [];
  const files = [];
  for (const dir of dirs) files.push(...discover(dir));

  for (const file of files) {
    try {
      const mod = await import(file);
      if (typeof mod.default !== "function") {
        errors.push({ file, error: "extension has no default-exported factory function" });
        continue;
      }
      await mod.default(longpi);
    } catch (err) {
      errors.push({ file, error: err && err.stack ? String(err.stack) : String(err) });
    }
  }

  const tools = [...TOOLS.values()].map((t) => ({
    name: t.name,
    description: t.description,
    parameters: t.parameters ?? { type: "object", properties: {} },
  }));
  const commands = [...COMMANDS.values()].map((c) => ({ name: c.name, description: c.description }));
  return { tools, commands, errors };
}

// --- execution ---------------------------------------------------------------

function toText(result) {
  if (result == null) return "";
  if (typeof result === "string") return result;
  const content = result.content;
  if (Array.isArray(content)) {
    return content
      .filter((c) => c && c.type === "text")
      .map((c) => c.text ?? "")
      .join("");
  }
  return typeof result === "object" ? JSON.stringify(result) : String(result);
}

async function callDef(map, kind, name, args) {
  const def = map.get(name);
  if (!def) return { ok: false, content: `unknown extension ${kind}: ${name}` };
  try {
    return { ok: true, content: toText(await def.execute(args ?? {}, { cwd: CWD })) };
  } catch (err) {
    return { ok: false, content: err instanceof Error ? (err.message ?? String(err)) : String(err) };
  }
}

async function fireEvent(event, payload) {
  for (const handler of HANDLERS.get(event) ?? []) {
    try {
      await handler(payload, { cwd: CWD });
    } catch (err) {
      errlog(`extension "${event}" handler error: ${String(err)}`);
    }
  }
}

// --- main loop ----------------------------------------------------------------

async function handle(msg) {
  switch (msg.type) {
    case "load": {
      CWD = msg.cwd || "/";
      applyEnv(msg.env);
      const { tools, commands, errors } = await loadAll(msg.dirs || []);
      writeFrame({ type: "ready", tools, commands, errors });
      break;
    }
    case "call": {
      applyEnv(msg.env);
      const { ok, content } = await callDef(TOOLS, "tool", msg.tool, msg.args);
      writeFrame({ type: "result", id: msg.id, ok, content });
      break;
    }
    case "command": {
      const { ok, content } = await callDef(COMMANDS, "command", msg.name, msg.args);
      writeFrame({ type: "result", id: msg.id, ok, content });
      break;
    }
    case "event":
      await fireEvent(msg.event, msg.payload);
      break;
  }
}

for (;;) {
  const msg = queuedFrames.length > 0 ? queuedFrames.shift() : readFrame();
  if (msg === null) break;
  try {
    await handle(msg);
  } catch (err) {
    errlog("host frame error: " + String(err));
  }
}
