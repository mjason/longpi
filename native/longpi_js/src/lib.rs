//! Native QuickJS extension host for longpi, via rquickjs.
//!
//! Replaces the earlier QuickJS-compiled-to-WASM-in-wasmtime host: since we
//! already link Rust (oxc for TS), the wasm layer was redundant weight. Here
//! QuickJS runs natively; capabilities (fetch, run, crypto, console) are Rust
//! host functions bound straight into the context — no frame protocol, no
//! stdio bridge, no wasm blob.
//!
//! One instance = one dedicated OS thread owning a single-threaded tokio
//! runtime + an rquickjs `AsyncRuntime`/`AsyncContext` (QuickJS is
//! single-threaded, so all JS and the registry live on that thread). NIF calls
//! send `Command`s over a channel; results return to the owner process as
//! `{:js_*, ...}` messages, mirroring the old host's async, GenServer-friendly
//! shape. Runaway scripts are stopped by an interrupt flag; memory is capped.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use futures_util::FutureExt;

use rquickjs::{
    prelude::{Async, Func},
    AsyncContext, AsyncRuntime, Function, Object, Persistent, Promise, Value,
};
use rustler::{Binary, Encoder, Env, LocalPid, NifResult, OwnedBinary, OwnedEnv, ResourceArc};
use tokio::sync::{mpsc, oneshot};

mod atoms {
    rustler::atoms! { ok, error, js_loaded, js_result, js_capability, js_down, js_event_done }
}

const MEMORY_LIMIT: usize = 64 * 1024 * 1024;
const HTTP_TIMEOUT_SECS: u64 = 30;
const HTTP_BODY_CAP: usize = 5_000_000;
// Upper bound on waiting for Elixir to service a brokered capability (run).
const CAPABILITY_TIMEOUT_SECS: u64 = 120;

// Capability requests (subprocess `run`) that must go through the BEAM — a
// NIF cannot spawn OS processes itself (it fights the BEAM's SIGCHLD reaping),
// so `longpi.run` is brokered to Elixir. Shared between the instance thread
// (which registers the waiter) and `capability_reply` (a NIF on another
// scheduler that fulfils it).
type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<String>>>>;

// A mutex lock that recovers a poisoned lock instead of panicking — a panic
// while another thread held it must not cascade into a second panic here.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ── TypeScript stripping (oxc) ──────────────────────────────────────────

fn strip_ts(source: &str) -> Result<String, String> {
    use oxc_allocator::Allocator;
    use oxc_codegen::Codegen;
    use oxc_parser::Parser;
    use oxc_semantic::SemanticBuilder;
    use oxc_span::SourceType;
    use oxc_transformer::{TransformOptions, Transformer};

    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts()).parse();
    if !parsed.errors.is_empty() {
        return Err(parsed
            .errors
            .iter()
            .map(|e| e.to_string())
            .collect::<Vec<_>>()
            .join("; "));
    }
    let mut program = parsed.program;
    let scoping = SemanticBuilder::new().build(&program).semantic.into_scoping();
    let path = std::path::Path::new("extension.ts");
    let _ = Transformer::new(&allocator, path, &TransformOptions::default())
        .build_with_scoping(scoping, &mut program);
    Ok(Codegen::new().build(&program).code)
}

// ── Instance / commands ─────────────────────────────────────────────────

enum Command {
    Load {
        extensions: Vec<(String, String)>,
        env: Vec<(String, String)>,
    },
    CallTool {
        call_id: u64,
        name: String,
        args_json: String,
        cwd: String,
        env: Vec<(String, String)>,
    },
    CallCommand {
        call_id: u64,
        name: String,
        args_json: String,
        cwd: String,
        env: Vec<(String, String)>,
    },
    FireEvent {
        event: String,
        payload_json: String,
    },
    Stop,
}

struct Instance {
    tx: mpsc::UnboundedSender<Command>,
    interrupt: Arc<AtomicBool>,
    pending: Pending,
    id: u64,
}

#[rustler::resource_impl]
impl rustler::Resource for Instance {}

// The tool/command/handler registry — Persistent JS callbacks kept alive on
// the runtime thread so we can invoke them for later tool calls.
#[derive(Default)]
struct Registry {
    tools: HashMap<String, ToolEntry>,
    commands: HashMap<String, CommandEntry>,
    handlers: HashMap<String, Vec<Persistent<Function<'static>>>>,
    // Preserves registration order for a stable UI listing.
    tool_order: Vec<String>,
    command_order: Vec<String>,
}

struct ToolEntry {
    description: String,
    parameters_json: String,
    execute: Persistent<Function<'static>>,
}

struct CommandEntry {
    description: String,
    execute: Persistent<Function<'static>>,
}

// ── Messaging back to the owner BEAM process ────────────────────────────

fn send_to(pid: &LocalPid, f: impl FnOnce(Env) -> rustler::Term) {
    let mut env = OwnedEnv::new();
    let _ = env.send_and_clear(pid, f);
}

fn binary_term<'a>(env: Env<'a>, data: &[u8]) -> Binary<'a> {
    let mut bin = OwnedBinary::new(data.len()).expect("alloc binary");
    bin.as_mut_slice().copy_from_slice(data);
    Binary::from_owned(bin, env)
}

// ── NIF surface ─────────────────────────────────────────────────────────

#[rustler::nif]
fn start(env: Env, id: u64) -> NifResult<ResourceArc<Instance>> {
    let owner = env.pid();
    let (tx, rx) = mpsc::unbounded_channel();
    let interrupt = Arc::new(AtomicBool::new(false));
    let interrupt_thread = interrupt.clone();
    let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
    let pending_thread = pending.clone();

    std::thread::Builder::new()
        .name(format!("longpi-js-{id}"))
        .spawn(move || {
            let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            // A fatal panic on this thread is contained here (never the BEAM);
            // the owning host then degrades gracefully via its call timeouts.
            let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
                rt.block_on(run_instance(id, owner, rx, interrupt_thread, pending_thread));
            }));
            if result.is_err() {
                eprintln!("[longpi-js:{id}] runtime thread panicked and stopped");
            }
            // Tell the owner the instance is gone so it can fail pending calls
            // and restart, instead of hanging every future call to its timeout.
            send_to(&owner, move |e| (atoms::js_down(), id).encode(e));
        })
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    Ok(ResourceArc::new(Instance {
        tx,
        interrupt,
        pending,
        id,
    }))
}

/// Fulfils a brokered capability request (see `Pending`): Elixir calls this
/// with the `req_id` from a `{:js_capability, ...}` message and the result
/// JSON, waking the `longpi.run` call that is awaiting it.
#[rustler::nif]
fn capability_reply(instance: ResourceArc<Instance>, req_id: u64, result: String) -> rustler::Atom {
    if let Some(sender) = lock(&instance.pending).remove(&req_id) {
        let _ = sender.send(result);
    }
    atoms::ok()
}

#[rustler::nif]
fn load(
    instance: ResourceArc<Instance>,
    extensions: Vec<(String, String)>,
    env: Vec<(String, String)>,
) -> rustler::Atom {
    let _ = instance.tx.send(Command::Load { extensions, env });
    atoms::ok()
}

#[rustler::nif]
fn call_tool(
    instance: ResourceArc<Instance>,
    call_id: u64,
    name: String,
    args_json: String,
    cwd: String,
    env: Vec<(String, String)>,
) -> rustler::Atom {
    let _ = instance.tx.send(Command::CallTool {
        call_id,
        name,
        args_json,
        cwd,
        env,
    });
    atoms::ok()
}

#[rustler::nif]
fn call_command(
    instance: ResourceArc<Instance>,
    call_id: u64,
    name: String,
    args_json: String,
    cwd: String,
    env: Vec<(String, String)>,
) -> rustler::Atom {
    let _ = instance.tx.send(Command::CallCommand {
        call_id,
        name,
        args_json,
        cwd,
        env,
    });
    atoms::ok()
}

#[rustler::nif]
fn fire_event(
    instance: ResourceArc<Instance>,
    event: String,
    payload_json: String,
) -> rustler::Atom {
    let _ = instance.tx.send(Command::FireEvent {
        event,
        payload_json,
    });
    atoms::ok()
}

#[rustler::nif]
fn interrupt(instance: ResourceArc<Instance>) -> rustler::Atom {
    instance.interrupt.store(true, Ordering::SeqCst);
    atoms::ok()
}

#[rustler::nif]
fn stop(instance: ResourceArc<Instance>) -> rustler::Atom {
    let _ = instance.tx.send(Command::Stop);
    atoms::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn strip_ts_nif(source: String) -> Result<String, String> {
    strip_ts(&source)
}

/// Decode raw file bytes to UTF-8: pass through when already valid UTF-8, else
/// detect a legacy encoding (GBK/Big5/Shift-JIS/EUC-KR/windows-*/…) and decode.
/// Used by the read tool for non-UTF-8 text files.
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_bytes(data: Binary) -> String {
    let bytes = data.as_slice();
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => detect_and_decode(bytes),
    }
}

// ── Instance runtime loop ───────────────────────────────────────────────

async fn run_instance(
    id: u64,
    owner: LocalPid,
    mut rx: mpsc::UnboundedReceiver<Command>,
    interrupt: Arc<AtomicBool>,
    pending: Pending,
) {
    let rt = match AsyncRuntime::new() {
        Ok(rt) => rt,
        Err(_) => return,
    };
    rt.set_memory_limit(MEMORY_LIMIT).await;

    // Runaway guard: the interrupt handler trips when the flag is set (the
    // watchdog / a close sets it), throwing out of the running script. It's
    // cleared after each command so it only kills the intended call.
    {
        let flag = interrupt.clone();
        rt.set_interrupt_handler(Some(Box::new(move || flag.load(Ordering::SeqCst))))
            .await;
    }

    let ctx = match AsyncContext::full(&rt).await {
        Ok(ctx) => ctx,
        Err(_) => return,
    };

    let registry: Rc<RefCell<Registry>> = Rc::new(RefCell::new(Registry::default()));
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());
    let http = Rc::new(http);

    let req_counter = Arc::new(AtomicU64::new(0));
    bind_globals(id, &ctx, registry.clone(), http.clone(), owner, pending.clone(), req_counter).await;

    while let Some(cmd) = rx.recv().await {
        interrupt.store(false, Ordering::SeqCst);
        if matches!(cmd, Command::Stop) {
            break;
        }

        // What to answer if this command panics, so a panic never leaves a
        // caller (or the host's load wait) hanging until its timeout.
        let reply_id = cmd.reply_kind();

        // Isolate each command: a panic (a resumed rquickjs callback panic, or
        // a bug in ours) is caught here so it kills only this call, never the
        // instance thread — the runtime stays usable for the next command.
        let outcome = AssertUnwindSafe(handle_command(id, owner, &ctx, &registry, cmd))
            .catch_unwind()
            .await;

        if outcome.is_err() {
            eprintln!("[longpi-js:{id}] command panicked; instance kept alive");
            match reply_id {
                Reply::Call(call_id) => send_to(&owner, move |e| {
                    let content = binary_term(e, b"extension runtime error (panic)");
                    (atoms::js_result(), id, call_id, false, content).encode(e)
                }),
                // A panicked load still needs a reply, else the host waits
                // ready?:false to its timeout.
                Reply::Load => send_to(&owner, move |e| {
                    let tools: Vec<(String, String, String)> = vec![];
                    let commands: Vec<(String, String)> = vec![];
                    let errors = vec![("<load>".to_string(), "load panicked".to_string())];
                    (atoms::js_loaded(), id, tools, commands, errors).encode(e)
                }),
                Reply::None => {}
            }
        }

        rt.idle().await;
    }

    // Drop all Persistent callbacks before the runtime is freed (else QuickJS
    // asserts on a non-empty GC object list at shutdown).
    registry.borrow_mut().clear();
    drop(ctx);
    rt.idle().await;
}

enum Reply {
    Call(u64),
    Load,
    None,
}

impl Command {
    fn reply_kind(&self) -> Reply {
        match self {
            Command::CallTool { call_id, .. } | Command::CallCommand { call_id, .. } => {
                Reply::Call(*call_id)
            }
            Command::Load { .. } => Reply::Load,
            _ => Reply::None,
        }
    }
}

// Processes one command and sends its result message(s). Panics here are
// caught by the caller (per-command isolation).
async fn handle_command(
    id: u64,
    owner: LocalPid,
    ctx: &AsyncContext,
    registry: &Rc<RefCell<Registry>>,
    cmd: Command,
) {
    match cmd {
        Command::Load { extensions, env } => {
            let errors = load_extensions(ctx, registry, extensions, env).await;
            let (tools, commands) = registry_summary(registry);
            send_to(&owner, move |e| {
                (atoms::js_loaded(), id, tools, commands, errors).encode(e)
            });
        }
        Command::CallTool {
            call_id,
            name,
            args_json,
            cwd,
            env,
        } => {
            apply_env(ctx, &env).await;
            let (ok, content) =
                call_registered(ctx, registry, Kind::Tool, &name, &args_json, &cwd).await;
            send_to(&owner, move |e| {
                let content = binary_term(e, content.as_bytes());
                (atoms::js_result(), id, call_id, ok, content).encode(e)
            });
        }
        Command::CallCommand {
            call_id,
            name,
            args_json,
            cwd,
            env,
        } => {
            apply_env(ctx, &env).await;
            let (ok, content) =
                call_registered(ctx, registry, Kind::Command, &name, &args_json, &cwd).await;
            send_to(&owner, move |e| {
                let content = binary_term(e, content.as_bytes());
                (atoms::js_result(), id, call_id, ok, content).encode(e)
            });
        }
        Command::FireEvent {
            event,
            payload_json,
        } => {
            fire_event_handlers(ctx, registry, &event, &payload_json).await;
            // Signal completion so the host can clear its watchdog — a hung
            // lifecycle handler would otherwise block the command queue silently.
            send_to(&owner, move |e| (atoms::js_event_done(), id).encode(e));
        }
        Command::Stop => {}
    }
}

impl Registry {
    fn clear(&mut self) {
        self.tools.clear();
        self.commands.clear();
        self.handlers.clear();
        self.tool_order.clear();
        self.command_order.clear();
    }
}

fn registry_summary(
    registry: &Rc<RefCell<Registry>>,
) -> (Vec<(String, String, String)>, Vec<(String, String)>) {
    let reg = registry.borrow();
    let tools = reg
        .tool_order
        .iter()
        .filter_map(|name| {
            reg.tools
                .get(name)
                .map(|t| (name.clone(), t.description.clone(), t.parameters_json.clone()))
        })
        .collect();
    let commands = reg
        .command_order
        .iter()
        .filter_map(|name| reg.commands.get(name).map(|c| (name.clone(), c.description.clone())))
        .collect();
    (tools, commands)
}

// ── Global bindings (console, fetch, crypto, process, longpi API) ────────

const PRELUDE: &str = r#"
globalThis.console = {
  log: (...a) => __log(a.map(x => typeof x === "string" ? x : JSON.stringify(x)).join(" ")),
};
globalThis.console.info = globalThis.console.log;
globalThis.console.warn = globalThis.console.log;
globalThis.console.error = globalThis.console.log;
globalThis.console.debug = globalThis.console.log;
globalThis.print = globalThis.console.log;

globalThis.crypto = globalThis.crypto || {};
globalThis.crypto.randomUUID = () => __uuid();

globalThis.process = globalThis.process || {};
globalThis.process.env = globalThis.process.env || {};

globalThis.structuredClone = globalThis.structuredClone ||
  ((v) => v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

globalThis.queueMicrotask = globalThis.queueMicrotask || ((fn) => Promise.resolve().then(fn));

// setTimeout/setInterval are built on the async __sleep primitive. Callbacks
// fire while the runtime is driven (during a tool/command/event invocation);
// a cancelled id short-circuits before firing (and stops an interval's loop).
globalThis.__timers = { seq: 0, cancelled: new Set() };
globalThis.setTimeout = (fn, ms, ...args) => {
  const id = ++__timers.seq;
  (async () => {
    await __sleep(Number(ms) || 0);
    if (!__timers.cancelled.has(id)) {
      try { fn(...args); } catch (e) { console.error(e); }
    }
  })();
  return id;
};
globalThis.setInterval = (fn, ms, ...args) => {
  const id = ++__timers.seq;
  (async () => {
    while (!__timers.cancelled.has(id)) {
      await __sleep(Number(ms) || 0);
      if (__timers.cancelled.has(id)) break;
      try { fn(...args); } catch (e) { console.error(e); }
    }
  })();
  return id;
};
globalThis.clearTimeout = (id) => { if (id != null) __timers.cancelled.add(id); };
globalThis.clearInterval = globalThis.clearTimeout;

if (typeof globalThis.atob === "undefined") {
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  globalThis.atob = (input) => {
    const str = String(input).replace(/[^A-Za-z0-9+/]/g, "");
    let out = "", bits = 0, acc = 0;
    for (const ch of str) {
      const v = B64.indexOf(ch);
      if (v < 0) continue;
      acc = (acc << 6) | v;
      bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 0xff); }
    }
    return out;
  };
  globalThis.btoa = (input) => {
    const s = String(input);
    let out = "";
    for (let i = 0; i < s.length; i += 3) {
      const a = s.charCodeAt(i);
      const b = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      const c = i + 2 < s.length ? s.charCodeAt(i + 2) : 0;
      out += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)] +
        (i + 1 < s.length ? B64[((b & 15) << 2) | (c >> 6)] : "=") +
        (i + 2 < s.length ? B64[c & 63] : "=");
    }
    return out;
  };
}

if (typeof globalThis.TextEncoder === "undefined") {
  globalThis.TextEncoder = class {
    encode(str) {
      const out = [];
      for (const ch of String(str)) {
        let cp = ch.codePointAt(0);
        if (cp < 0x80) out.push(cp);
        else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
        else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      }
      return new Uint8Array(out);
    }
  };
  globalThis.TextDecoder = class {
    decode(bytes) {
      const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      let out = "";
      for (let i = 0; i < b.length; ) {
        const c = b[i];
        let cp, n;
        if (c < 0x80) { cp = c; n = 0; }
        else if (c < 0xe0) { cp = c & 31; n = 1; }
        else if (c < 0xf0) { cp = c & 15; n = 2; }
        else { cp = c & 7; n = 3; }
        for (let j = 1; j <= n; j++) cp = (cp << 6) | (b[i + j] & 63);
        out += String.fromCodePoint(cp);
        i += n + 1;
      }
      return out;
    }
  };
}

globalThis.fetch = async (url, options = {}) => {
  const res = JSON.parse(await __http(JSON.stringify({
    url: String(url),
    method: options.method || "GET",
    headers: options.headers || {},
    body: options.body ?? null,
  })));
  if (res.error) throw new Error("fetch failed: " + res.error);
  const headers = res.headers || {};
  const lower = {};
  for (const k in headers) lower[k.toLowerCase()] = headers[k];
  // Text responses arrive as `body` (UTF-8); binary responses (invalid UTF-8)
  // arrive intact as base64 in `bodyB64` so arrayBuffer() isn't lossy.
  const toBytes = () => {
    if (res.bodyB64) {
      const bin = atob(res.bodyB64);
      const u = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
      return u;
    }
    return new TextEncoder().encode(res.body || "");
  };
  return {
    ok: res.status >= 200 && res.status < 300,
    status: res.status,
    statusText: res.statusText || String(res.status),
    headers: { get: (k) => lower[String(k).toLowerCase()] ?? null },
    text: async () => res.body || "",
    json: async () => JSON.parse(res.body || "null"),
    arrayBuffer: async () => toBytes().buffer,
    bytes: async () => toBytes(),
  };
};

globalThis.__makeLongpi = (registerTool, registerCommand, on) => ({
  registerTool,
  registerCommand,
  on,
  run: async (cmd, args = [], opts = {}) => JSON.parse(await __run(JSON.stringify({ cmd: String(cmd), args, opts }))),
});
"#;

async fn bind_globals(
    id: u64,
    ctx: &AsyncContext,
    registry: Rc<RefCell<Registry>>,
    http: Rc<reqwest::Client>,
    owner: LocalPid,
    pending: Pending,
    req_counter: Arc<AtomicU64>,
) {
    rquickjs::async_with!(ctx => |ctx| {
        let g = ctx.globals();

        g.set("__log", Func::from(|msg: String| eprintln!("[ext] {msg}"))).ok();

        g.set("__uuid", Func::from(|| uuid_v4())).ok();

        let http2 = http.clone();
        g.set("__http", Func::from(Async(move |req: String| {
            let http = http2.clone();
            async move { http_request(&http, req).await }
        }))).ok();

        // `run` is brokered to Elixir (a NIF can't spawn OS processes safely).
        g.set("__run", Func::from(Async(move |req: String| {
            let pending = pending.clone();
            let counter = req_counter.clone();
            async move { broker_run(id, owner, &pending, &counter, req).await }
        }))).ok();

        // longpi API primitives that mutate the Rust registry.
        let reg_tool = registry.clone();
        g.set("__registerTool", Func::from(move |def: Object<'_>| -> rquickjs::Result<()> {
            let name: String = def.get("name")?;
            let description: String = def.get("description").unwrap_or_default();
            let parameters_json = def
                .get::<_, Value>("parameters")
                .ok()
                .and_then(|v| stringify(def.ctx(), &v))
                .unwrap_or_else(|| "{\"type\":\"object\",\"properties\":{}}".to_string());
            let execute: Function = def.get("execute")?;
            let saved = Persistent::save(def.ctx(), execute);
            let mut reg = reg_tool.borrow_mut();
            if !reg.tools.contains_key(&name) {
                reg.tool_order.push(name.clone());
            }
            reg.tools.insert(name, ToolEntry { description, parameters_json, execute: saved });
            Ok(())
        })).ok();

        let reg_cmd = registry.clone();
        g.set("__registerCommand", Func::from(move |name: String, def: Object<'_>| -> rquickjs::Result<()> {
            let description: String = def.get("description").unwrap_or_default();
            let execute: Function = def.get("execute")?;
            let saved = Persistent::save(def.ctx(), execute);
            let mut reg = reg_cmd.borrow_mut();
            if !reg.commands.contains_key(&name) {
                reg.command_order.push(name.clone());
            }
            reg.commands.insert(name, CommandEntry { description, execute: saved });
            Ok(())
        })).ok();

        // The async primitive setTimeout/setInterval are built on: returns a
        // promise resolving after `ms`, driven by the same executor that runs
        // tool calls — so `await new Promise(r => setTimeout(r, n))` inside a
        // tool resolves mid-call (like fetch/run do).
        g.set("__sleep", Func::from(Async(move |ms: f64| async move {
            let delay = if ms.is_finite() && ms > 0.0 { ms as u64 } else { 0 };
            tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
        }))).ok();

        let reg_on = registry.clone();
        g.set("__on", Func::from(move |event: String, handler: Function<'_>| -> rquickjs::Result<()> {
            let hctx = handler.ctx().clone();
            let saved = Persistent::save(&hctx, handler);
            reg_on.borrow_mut().handlers.entry(event).or_default().push(saved);
            Ok(())
        })).ok();

        ctx.eval::<(), _>(PRELUDE).ok();
    })
    .await;
}

async fn apply_env(ctx: &AsyncContext, env: &[(String, String)]) {
    let json = {
        let pairs: Vec<String> = env
            .iter()
            .map(|(k, v)| format!("{}:{}", json_string(k), json_string(v)))
            .collect();
        format!("{{{}}}", pairs.join(","))
    };
    let script = format!("globalThis.process.env = {json};");
    rquickjs::async_with!(ctx => |ctx| {
        ctx.eval::<(), _>(script).ok();
    })
    .await;
}

// ── Extension loading ───────────────────────────────────────────────────

async fn load_extensions(
    ctx: &AsyncContext,
    registry: &Rc<RefCell<Registry>>,
    extensions: Vec<(String, String)>,
    env: Vec<(String, String)>,
) -> Vec<(String, String)> {
    registry.borrow_mut().clear();
    apply_env(ctx, &env).await;

    let mut errors = Vec::new();
    for (i, (name, source)) in extensions.into_iter().enumerate() {
        let js = match strip_ts(&source) {
            Ok(js) => js,
            Err(_) => source, // let QuickJS surface the real syntax error
        };
        let module_name = format!("ext{i}");
        if let Err(message) = eval_extension(ctx, &module_name, &js).await {
            errors.push((name, message));
        }
    }
    errors
}

async fn eval_extension(ctx: &AsyncContext, module_name: &str, js: &str) -> Result<(), String> {
    let module_name = module_name.to_string();
    let js = js.to_string();
    rquickjs::async_with!(ctx => |ctx| {
        let declared = rquickjs::Module::declare(ctx.clone(), module_name, js)
            .map_err(|e| fmt_err(&ctx, e))?;
        let (evaluated, promise) = declared.eval().map_err(|e| fmt_err(&ctx, e))?;
        promise.into_future::<()>().await.map_err(|e| fmt_err(&ctx, e))?;

        let default: Function = evaluated.get("default").map_err(|_| {
            "extension has no default-exported factory function".to_string()
        })?;

        // Build the `longpi` API object from the bound primitives and pass it in.
        let make: Function = ctx.globals().get("__makeLongpi").map_err(|e| fmt_err(&ctx, e))?;
        let reg_tool: Value = ctx.globals().get("__registerTool").map_err(|e| fmt_err(&ctx, e))?;
        let reg_cmd: Value = ctx.globals().get("__registerCommand").map_err(|e| fmt_err(&ctx, e))?;
        let on: Value = ctx.globals().get("__on").map_err(|e| fmt_err(&ctx, e))?;
        let longpi: Value = make.call((reg_tool, reg_cmd, on)).map_err(|e| fmt_err(&ctx, e))?;

        let result: Value = default.call((longpi,)).map_err(|e| fmt_err(&ctx, e))?;
        if let Some(promise) = result.as_promise() {
            promise.clone().into_future::<()>().await.map_err(|e| fmt_err(&ctx, e))?;
        }
        Ok(())
    })
    .await
}

// ── Tool / command invocation ───────────────────────────────────────────

enum Kind {
    Tool,
    Command,
}

async fn call_registered(
    ctx: &AsyncContext,
    registry: &Rc<RefCell<Registry>>,
    kind: Kind,
    name: &str,
    args_json: &str,
    cwd: &str,
) -> (bool, String) {
    let execute = {
        let reg = registry.borrow();
        match kind {
            Kind::Tool => reg.tools.get(name).map(|t| t.execute.clone()),
            Kind::Command => reg.commands.get(name).map(|c| c.execute.clone()),
        }
    };

    let Some(execute) = execute else {
        let label = match kind {
            Kind::Tool => "tool",
            Kind::Command => "command",
        };
        return (false, format!("unknown extension {label}: {name}"));
    };

    let args_json = args_json.to_string();
    let cwd = cwd.to_string();
    rquickjs::async_with!(ctx => |ctx| {
        let run = async {
            let execute = execute.clone().restore(&ctx)?;
            let args: Value = ctx.json_parse(args_json)?;
            let ctx_obj = Object::new(ctx.clone())?;
            ctx_obj.set("cwd", cwd.as_str())?;
            let result: Value = execute.call((args, ctx_obj))?;
            let text = if let Some(promise) = result.as_promise() {
                promise.clone().into_future::<Value>().await?
            } else {
                result
            };
            to_text(&ctx, text)
        };
        match run.await {
            Ok(text) => (true, text),
            Err(e) => (false, fmt_err(&ctx, e)),
        }
    })
    .await
}

async fn fire_event_handlers(
    ctx: &AsyncContext,
    registry: &Rc<RefCell<Registry>>,
    event: &str,
    payload_json: &str,
) {
    let handlers = {
        let reg = registry.borrow();
        reg.handlers.get(event).map(|hs| hs.iter().map(|h| h.clone()).collect::<Vec<_>>())
    };
    let Some(handlers) = handlers else { return };

    let payload_json = payload_json.to_string();
    rquickjs::async_with!(ctx => |ctx| {
        for handler in handlers {
            let Ok(func) = handler.restore(&ctx) else { continue };
            let Ok(ctx_obj) = Object::new(ctx.clone()) else { continue };
            let payload = ctx
                .json_parse(payload_json.clone())
                .unwrap_or_else(|_| Value::new_undefined(ctx.clone()));
            if let Ok(result) = func.call::<_, Value>((payload, ctx_obj)) {
                if let Some(promise) = result.as_promise() {
                    let _ = promise.clone().into_future::<Value>().await;
                }
            }
        }
    })
    .await;
}

// ── JS value helpers ────────────────────────────────────────────────────

// pi's toText: a string is returned as-is; a `{content:[{type:"text",text}]}`
// object is flattened; anything else is JSON.
fn to_text<'js>(ctx: &rquickjs::Ctx<'js>, value: Value<'js>) -> rquickjs::Result<String> {
    if value.is_null() || value.is_undefined() {
        return Ok(String::new());
    }
    if let Some(s) = value.as_string() {
        return s.to_string();
    }
    if let Some(obj) = value.as_object() {
        if let Ok(content) = obj.get::<_, rquickjs::Array>("content") {
            let mut out = String::new();
            for item in content.iter::<Object>().flatten() {
                let ty: String = item.get("type").unwrap_or_default();
                if ty == "text" {
                    let text: String = item.get("text").unwrap_or_default();
                    out.push_str(&text);
                }
            }
            return Ok(out);
        }
    }
    Ok(stringify(ctx, &value).unwrap_or_default())
}

fn stringify<'js>(ctx: &rquickjs::Ctx<'js>, value: &Value<'js>) -> Option<String> {
    ctx.json_stringify(value.clone()).ok().flatten().and_then(|s| s.to_string().ok())
}

fn fmt_err(ctx: &rquickjs::Ctx<'_>, err: rquickjs::Error) -> String {
    if let rquickjs::Error::Exception = err {
        let exc = ctx.catch();
        if let Some(obj) = exc.as_object() {
            let message: String = obj.get("message").unwrap_or_default();
            let stack: String = obj.get("stack").unwrap_or_default();
            if !stack.is_empty() {
                return format!("{message}\n{stack}");
            }
            if !message.is_empty() {
                return message;
            }
        }
        if let Some(s) = exc.as_string() {
            if let Ok(s) = s.to_string() {
                return s;
            }
        }
    }
    err.to_string()
}

// ── HTTP / process / uuid host functions ────────────────────────────────

async fn http_request(client: &reqwest::Client, req_json: String) -> String {
    match do_http(client, &req_json).await {
        Ok(json) => json,
        Err(e) => format!("{{\"error\":{}}}", json_string(&e)),
    }
}

async fn do_http(client: &reqwest::Client, req_json: &str) -> Result<String, String> {
    let req: HttpReq = parse_http_req(req_json)?;
    let method = reqwest::Method::from_bytes(req.method.to_uppercase().as_bytes())
        .map_err(|e| e.to_string())?;
    let mut builder = client.request(method, &req.url);
    for (k, v) in &req.headers {
        builder = builder.header(k, v);
    }
    if let Some(body) = req.body {
        builder = builder.body(body);
    }
    let resp = builder.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let status_text = resp.status().canonical_reason().unwrap_or("").to_string();
    // Capture before the body consumes `resp`: drives text-vs-binary + charset.
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let mut headers = String::from("{");
    let mut first = true;
    for (k, v) in resp.headers().iter() {
        if !first {
            headers.push(',');
        }
        first = false;
        headers.push_str(&json_string(k.as_str()));
        headers.push(':');
        headers.push_str(&json_string(v.to_str().unwrap_or("")));
    }
    headers.push('}');

    let bytes = resp.bytes().await.map_err(|e| e.to_string())?;
    let capped = if bytes.len() > HTTP_BODY_CAP {
        &bytes[..HTTP_BODY_CAP]
    } else {
        &bytes[..]
    };

    // Text responses (by content-type) are decoded to UTF-8 using the declared
    // charset, else UTF-8 if valid, else a detected legacy encoding (GBK/Big5/
    // Shift-JIS/…) — so `res.text()` reads correctly instead of mojibake.
    // Binary responses ride intact as base64 in `bodyB64` for arrayBuffer().
    let (body, body_b64) = if is_textual(&content_type) {
        (json_string(&decode_text(capped, &content_type)), "null".to_string())
    } else {
        ("\"\"".to_string(), json_string(&base64_encode(capped)))
    };

    Ok(format!(
        "{{\"status\":{status},\"statusText\":{},\"headers\":{headers},\"body\":{body},\"bodyB64\":{body_b64}}}",
        json_string(&status_text),
    ))
}

fn is_textual(content_type: &str) -> bool {
    let ct = content_type.to_ascii_lowercase();
    ct.is_empty()
        || ct.starts_with("text/")
        || ct.contains("json")
        || ct.contains("xml")
        || ct.contains("javascript")
        || ct.contains("html")
        || ct.contains("csv")
        || ct.contains("charset=")
}

// Decode bytes to UTF-8: an explicit Content-Type charset wins; otherwise use
// UTF-8 when the bytes are valid, else detect the encoding (chardetng) — which
// also recovers pages that lie in a <meta charset> but serve legacy bytes.
fn decode_text(bytes: &[u8], content_type: &str) -> String {
    if let Some(label) = charset_label(content_type) {
        if let Some(enc) = encoding_rs::Encoding::for_label(label.as_bytes()) {
            return enc.decode(bytes).0.into_owned();
        }
    }

    if let Ok(text) = std::str::from_utf8(bytes) {
        return text.to_string();
    }

    detect_and_decode(bytes)
}

fn detect_and_decode(bytes: &[u8]) -> String {
    let mut detector = chardetng::EncodingDetector::new();
    detector.feed(bytes, true);
    detector.guess(None, true).decode(bytes).0.into_owned()
}

fn charset_label(content_type: &str) -> Option<String> {
    let lower = content_type.to_ascii_lowercase();
    let start = lower.find("charset=")? + "charset=".len();
    let rest = &content_type[start..];
    let end = rest.find([';', ' ']).unwrap_or(rest.len());
    Some(rest[..end].trim().trim_matches('"').to_string())
}

// Standard base64 (with padding); no external dependency.
fn base64_encode(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0];
        let b1 = chunk.get(1).copied().unwrap_or(0);
        let b2 = chunk.get(2).copied().unwrap_or(0);
        out.push(T[(b0 >> 2) as usize] as char);
        out.push(T[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 { T[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[(b2 & 0x3f) as usize] as char } else { '=' });
    }
    out
}

struct HttpReq {
    url: String,
    method: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
}

// A minimal, dependency-free extraction of the fields we send from JS (which
// are always well-formed JSON we produced). Uses a tiny JSON scan.
fn parse_http_req(json: &str) -> Result<HttpReq, String> {
    let v = json_parse(json).ok_or("bad request json")?;
    let obj = v.as_object().ok_or("request not an object")?;
    Ok(HttpReq {
        url: obj.get("url").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        method: obj.get("method").and_then(|v| v.as_str()).unwrap_or("GET").to_string(),
        headers: obj
            .get("headers")
            .and_then(|v| v.as_object())
            .map(|h| {
                h.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default(),
        body: obj.get("body").and_then(|v| v.as_str()).map(|s| s.to_string()),
    })
}

// Brokers a `run` request to Elixir and awaits the result. Registers a waiter
// keyed by a fresh req_id, tells Elixir to service it, and blocks (with a
// timeout) on the reply delivered via `capability_reply`.
async fn broker_run(
    id: u64,
    owner: LocalPid,
    pending: &Pending,
    counter: &AtomicU64,
    req_json: String,
) -> String {
    let req_id = counter.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = oneshot::channel();
    lock(pending).insert(req_id, tx);

    send_to(&owner, move |e| {
        let cap = binary_term(e, b"run");
        let payload = binary_term(e, req_json.as_bytes());
        (atoms::js_capability(), id, req_id, cap, payload).encode(e)
    });

    match tokio::time::timeout(std::time::Duration::from_secs(CAPABILITY_TIMEOUT_SECS), rx).await {
        Ok(Ok(result)) => result,
        _ => {
            lock(pending).remove(&req_id);
            "{\"status\":124,\"stdout\":\"\",\"stderr\":\"run broker timed out\"}".to_string()
        }
    }
}

fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    let _ = getrandom::getrandom(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let h = |b: u8| format!("{b:02x}");
    format!(
        "{}{}{}{}-{}{}-{}{}-{}{}-{}{}{}{}{}{}",
        h(bytes[0]), h(bytes[1]), h(bytes[2]), h(bytes[3]),
        h(bytes[4]), h(bytes[5]), h(bytes[6]), h(bytes[7]),
        h(bytes[8]), h(bytes[9]), h(bytes[10]), h(bytes[11]),
        h(bytes[12]), h(bytes[13]), h(bytes[14]), h(bytes[15]),
    )
}

// ── Tiny JSON (for host-function request parsing; JS produces valid JSON) ──

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// Minimal JSON parser for host-function request payloads.
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn as_object(&self) -> Option<&Vec<(String, Json)>> {
        if let Json::Obj(o) = self {
            Some(o)
        } else {
            None
        }
    }
    fn as_array(&self) -> Option<&Vec<Json>> {
        if let Json::Arr(a) = self {
            Some(a)
        } else {
            None
        }
    }
    fn as_str(&self) -> Option<&str> {
        if let Json::Str(s) = self {
            Some(s)
        } else {
            None
        }
    }
}

trait JsonObjExt {
    fn get(&self, key: &str) -> Option<&Json>;
}
impl JsonObjExt for Vec<(String, Json)> {
    fn get(&self, key: &str) -> Option<&Json> {
        self.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
}

fn json_parse(s: &str) -> Option<Json> {
    let mut chars: Vec<char> = s.chars().collect();
    let mut pos = 0;
    parse_value(&mut chars, &mut pos, 0)
}

const JSON_MAX_DEPTH: usize = 256;

fn skip_ws(c: &[char], p: &mut usize) {
    while *p < c.len() && c[*p].is_whitespace() {
        *p += 1;
    }
}

fn parse_value(c: &mut Vec<char>, p: &mut usize, depth: usize) -> Option<Json> {
    if depth > JSON_MAX_DEPTH {
        return None;
    }
    skip_ws(c, p);
    match c.get(*p)? {
        '{' => parse_obj(c, p, depth),
        '[' => parse_arr(c, p, depth),
        '"' => parse_str(c, p).map(Json::Str),
        't' => {
            *p += 4;
            Some(Json::Bool(true))
        }
        'f' => {
            *p += 5;
            Some(Json::Bool(false))
        }
        'n' => {
            *p += 4;
            Some(Json::Null)
        }
        _ => parse_num(c, p),
    }
}

fn parse_str(c: &mut Vec<char>, p: &mut usize) -> Option<String> {
    *p += 1; // opening quote
    let mut out = String::new();
    while *p < c.len() {
        let ch = c[*p];
        *p += 1;
        match ch {
            '"' => return Some(out),
            '\\' => {
                let esc = c.get(*p)?;
                *p += 1;
                match esc {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'b' => out.push('\u{08}'),
                    'f' => out.push('\u{0c}'),
                    'u' => {
                        let hex: String = c.get(*p..*p + 4)?.iter().collect();
                        *p += 4;
                        let code = u32::from_str_radix(&hex, 16).ok()?;
                        out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
                    }
                    other => out.push(*other),
                }
            }
            other => out.push(other),
        }
    }
    None
}

fn parse_num(c: &mut Vec<char>, p: &mut usize) -> Option<Json> {
    let start = *p;
    while *p < c.len() && (c[*p].is_ascii_digit() || matches!(c[*p], '-' | '+' | '.' | 'e' | 'E')) {
        *p += 1;
    }
    let s: String = c[start..*p].iter().collect();
    s.parse::<f64>().ok().map(Json::Num)
}

fn parse_arr(c: &mut Vec<char>, p: &mut usize, depth: usize) -> Option<Json> {
    *p += 1; // [
    let mut out = Vec::new();
    loop {
        skip_ws(c, p);
        if c.get(*p)? == &']' {
            *p += 1;
            return Some(Json::Arr(out));
        }
        out.push(parse_value(c, p, depth + 1)?);
        skip_ws(c, p);
        match c.get(*p)? {
            ',' => *p += 1,
            ']' => {
                *p += 1;
                return Some(Json::Arr(out));
            }
            _ => return None,
        }
    }
}

fn parse_obj(c: &mut Vec<char>, p: &mut usize, depth: usize) -> Option<Json> {
    *p += 1; // {
    let mut out = Vec::new();
    loop {
        skip_ws(c, p);
        match c.get(*p)? {
            '}' => {
                *p += 1;
                return Some(Json::Obj(out));
            }
            '"' => {}
            _ => return None,
        }
        let key = parse_str(c, p)?;
        skip_ws(c, p);
        if c.get(*p)? != &':' {
            return None;
        }
        *p += 1;
        let val = parse_value(c, p, depth + 1)?;
        out.push((key, val));
        skip_ws(c, p);
        match c.get(*p)? {
            ',' => *p += 1,
            '}' => {
                *p += 1;
                return Some(Json::Obj(out));
            }
            _ => return None,
        }
    }
}

rustler::init!("Elixir.Longpi.Js.Native");
