//! Minimal wasmtime wrapper for longpi's Wasm extension host.
//!
//! Deliberately tiny (the reason we can maintain it ourselves instead of
//! depending on a full binding like wasmex): one NIF surface that
//!
//!   * instantiates a WASI-p1 module (QuickJS) with stdio bridged to the BEAM,
//!   * pushes length-prefixed frames INTO the guest (`send_frame`),
//!   * delivers frames OUT of the guest as `{:wasm_frame, id, binary}`
//!     messages to an owner pid (plus `{:wasm_exit, id, reason}` on death),
//!   * kills runaway guests via epoch interruption (`interrupt`).
//!
//! One OS thread per live guest (it blocks on the guest's stdin) plus one
//! pump thread reading guest stdout. Fine at the scale of "sessions on one
//! machine"; each guest is a few MB.

use std::io::{Read, Write};
use std::sync::Mutex;

use rustler::types::atom::Atom;
use rustler::{Binary, Encoder, Env, LocalPid, NifResult, OwnedBinary, OwnedEnv, ResourceArc};
use wasmtime::{Config, Engine, Linker, Module, Store};
use wasmtime_wasi::preview1::{self, WasiP1Ctx};
use wasmtime_wasi::{AsyncStdinStream, AsyncStdoutStream, DirPerms, FilePerms, WasiCtxBuilder};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        wasm_frame,
        wasm_exit,
        normal,
        trap,
        closed,
    }
}

/// Live guest handle: the stdin writer (frames in) and the engine (epoch bump
/// to interrupt). Everything else lives on the guest thread.
struct Instance {
    stdin: Mutex<Option<os_pipe::PipeWriter>>,
    engine: Engine,
    id: u64,
}

#[rustler::resource_impl]
impl rustler::Resource for Instance {}

// wasmtime's Engine isn't RefUnwindSafe by declaration, but we never touch it
// across catch_unwind boundaries in a way that could observe broken invariants
// (interrupt() only bumps an atomic epoch counter).
impl std::panic::RefUnwindSafe for Instance {}

fn send_to(pid: &LocalPid, f: impl FnOnce(Env) -> rustler::Term) {
    let mut env = OwnedEnv::new();
    let _ = env.send_and_clear(pid, f);
}

/// Starts a guest: `wasm_path` module with WASI args `argv`, preopening each
/// `(host_dir, guest_path)` read-only. Frames the guest writes to stdout
/// arrive at `owner` as `{:wasm_frame, id, binary}`.
#[rustler::nif(schedule = "DirtyIo")]
fn start(
    env: Env,
    wasm_path: String,
    preopens: Vec<(String, String)>,
    argv: Vec<String>,
    id: u64,
) -> NifResult<ResourceArc<Instance>> {
    let owner = env.pid();

    let mut config = Config::new();
    config.epoch_interruption(true);
    let engine =
        Engine::new(&config).map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let module = Module::from_file(&engine, &wasm_path)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let (stdin_read, stdin_write) = os_pipe::pipe().map_err(io_err)?;
    let (stdout_read, stdout_write) = os_pipe::pipe().map_err(io_err)?;

    let stdin_file = std::fs::File::from(std::os::fd::OwnedFd::from(stdin_read));
    let stdout_file = std::fs::File::from(std::os::fd::OwnedFd::from(stdout_write));

    let mut builder = WasiCtxBuilder::new();
    builder
        .stdin(AsyncStdinStream::new(
            wasmtime_wasi::pipe::AsyncReadStream::new(tokio::fs::File::from_std(stdin_file)),
        ))
        .stdout(AsyncStdoutStream::new(
            wasmtime_wasi::pipe::AsyncWriteStream::new(
                64 * 1024,
                tokio::fs::File::from_std(stdout_file),
            ),
        ))
        .inherit_stderr()
        .args(&argv);

    for (host_dir, guest_path) in &preopens {
        builder
            .preopened_dir(host_dir, guest_path, DirPerms::READ, FilePerms::READ)
            .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
    }

    let wasi: WasiP1Ctx = builder.build_p1();

    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    preview1::add_to_linker_sync(&mut linker, |t| t)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    let mut store = Store::new(&engine, wasi);
    // Deadline 1, never bumped in normal operation; `interrupt` bumps the
    // epoch which traps the guest wherever it is (including hot loops).
    store.set_epoch_deadline(1);

    // Guest thread: run _start to completion (or trap), then report exit.
    let guest_owner = owner;
    std::thread::spawn(move || {
        let result = (|| -> anyhow::Result<()> {
            let instance = linker.instantiate(&mut store, &module)?;
            let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
            start.call(&mut store, ())?;
            Ok(())
        })();

        let reason = match result {
            Ok(()) => atoms::normal(),
            Err(_) => atoms::trap(),
        };
        send_to(&guest_owner, |env| {
            (atoms::wasm_exit(), id, reason).encode(env)
        });
    });

    // Pump thread: guest stdout frames → owner mailbox.
    let pump_owner = owner;
    std::thread::spawn(move || {
        let mut reader = stdout_read;
        loop {
            let mut head = [0u8; 4];
            if reader.read_exact(&mut head).is_err() {
                break;
            }
            let len = u32::from_be_bytes(head) as usize;
            // Frame size guard: a guest shouldn't be able to OOM the BEAM.
            if len > 32 * 1024 * 1024 {
                break;
            }
            let mut body = vec![0u8; len];
            if reader.read_exact(&mut body).is_err() {
                break;
            }
            send_to(&pump_owner, |env| {
                let mut bin = OwnedBinary::new(body.len()).expect("alloc binary");
                bin.as_mut_slice().copy_from_slice(&body);
                (
                    atoms::wasm_frame(),
                    id,
                    Binary::from_owned(bin, env),
                )
                    .encode(env)
            });
        }
    });

    Ok(ResourceArc::new(Instance {
        stdin: Mutex::new(Some(stdin_write)),
        engine,
        id,
    }))
}

/// Writes one length-prefixed frame into the guest's stdin.
#[rustler::nif(schedule = "DirtyIo")]
fn send_frame(instance: ResourceArc<Instance>, payload: Binary) -> NifResult<Atom> {
    let mut guard = instance.stdin.lock().unwrap();
    match guard.as_mut() {
        Some(writer) => {
            let head = (payload.len() as u32).to_be_bytes();
            writer.write_all(&head).map_err(io_err)?;
            writer.write_all(payload.as_slice()).map_err(io_err)?;
            writer.flush().map_err(io_err)?;
            Ok(atoms::ok())
        }
        None => Err(rustler::Error::Term(Box::new("closed"))),
    }
}

/// Traps the guest wherever it is (epoch bump) — the kill switch for
/// runaway extension code.
#[rustler::nif]
fn interrupt(instance: ResourceArc<Instance>) -> Atom {
    instance.engine.increment_epoch();
    atoms::ok()
}

/// Closes the guest's stdin (EOF): a well-behaved harness exits its loop.
#[rustler::nif]
fn close_stdin(instance: ResourceArc<Instance>) -> Atom {
    let mut guard = instance.stdin.lock().unwrap();
    *guard = None;
    atoms::ok()
}

/// The instance's id (as passed to start/1) — for matching messages.
#[rustler::nif]
fn instance_id(instance: ResourceArc<Instance>) -> u64 {
    instance.id
}

fn io_err(e: std::io::Error) -> rustler::Error {
    rustler::Error::Term(Box::new(e.to_string()))
}

/// Strips TypeScript type syntax from `source`, returning plain JavaScript the
/// QuickJS guest can run. Extensions are authored in TS (type annotations,
/// `as` casts, generics); QuickJS has no transpiler, so we erase the types
/// here. On a genuine parse error, returns `{:error, message}` so the caller
/// can surface it. JavaScript in, JavaScript out — it's a no-op for plain JS.
#[rustler::nif(schedule = "DirtyCpu")]
fn strip_ts(source: String) -> Result<String, String> {
    use oxc_allocator::Allocator;
    use oxc_codegen::Codegen;
    use oxc_parser::Parser;
    use oxc_semantic::SemanticBuilder;
    use oxc_span::SourceType;
    use oxc_transformer::{TransformOptions, Transformer};

    let allocator = Allocator::default();
    let source_type = SourceType::ts();
    let parsed = Parser::new(&allocator, &source, source_type).parse();

    if !parsed.errors.is_empty() {
        let msg = parsed
            .errors
            .iter()
            .map(|e| e.to_string())
            .collect::<Vec<_>>()
            .join("; ");
        return Err(msg);
    }

    let mut program = parsed.program;
    let scoping = SemanticBuilder::new().build(&program).semantic.into_scoping();
    let path = std::path::Path::new("extension.ts");
    let options = TransformOptions::default();
    let _ = Transformer::new(&allocator, path, &options).build_with_scoping(scoping, &mut program);

    Ok(Codegen::new().build(&program).code)
}

rustler::init!("Elixir.Longpi.Wasm.Native");
