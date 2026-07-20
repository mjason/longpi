//! longpi_shim — cross-platform process supervisor for the Longpi shell tool.
//!
//! Spoken protocol: length-prefixed frames (4-byte big-endian length, matching
//! Erlang's `{:packet, 4}`), first payload byte is the frame type.
//!
//! Inbound (BEAM -> shim):   0x01 RUN (json)   0x02 KILL (json)
//!                           0x03 STDIN (raw)  0x04 RESIZE (json)
//! Outbound (shim -> BEAM):  0x11 OUTPUT (raw) 0x13 EXIT (json)
//!                           0x14 ERROR (json) 0x15 TAIL (raw)
//!
//! Lifeline: EOF on our stdin means the BEAM is gone (or closed the port).
//! We kill the whole child process tree and exit. Under no circumstances may
//! a child outlive an unreachable parent.

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const F_RUN: u8 = 0x01;
const F_KILL: u8 = 0x02;
const F_STDIN: u8 = 0x03;
const F_RESIZE: u8 = 0x04;
const F_OUTPUT: u8 = 0x11;
const F_EXIT: u8 = 0x13;
const F_ERROR: u8 = 0x14;
const F_TAIL: u8 = 0x15;

const DEFAULT_MAX_OUTPUT: u64 = 1024 * 1024; // forwarded head bytes
const TAIL_CAPACITY: usize = 64 * 1024;
const LIFELINE_GRACE_MS: u64 = 2000;
const FLUSH_AFTER_EXIT_MS: u64 = 300;

#[derive(Deserialize)]
struct RunCfg {
    argv: Vec<String>,
    cwd: Option<String>,
    #[serde(default)]
    env: HashMap<String, String>,
    rows: Option<u16>,
    cols: Option<u16>,
    max_output_bytes: Option<u64>,
}

#[derive(Deserialize)]
struct KillCfg {
    grace_ms: Option<u64>,
}

#[derive(Deserialize)]
struct ResizeCfg {
    rows: u16,
    cols: u16,
}

#[derive(Serialize)]
struct ExitMsg {
    exit_code: u32,
    dropped_bytes: u64,
    killed: bool,
}

enum Event {
    Output(Vec<u8>),
    ReaderEof,
    ChildExited(u32),
    Kill(u64),
    Resize(u16, u16),
    StdinClosed,
}

fn read_frame(r: &mut impl Read) -> std::io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let mut buf = vec![0u8; u32::from_be_bytes(len) as usize];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

fn write_frame(out: &mut impl Write, ftype: u8, payload: &[u8]) {
    // Writes are best-effort: if the BEAM is gone the pipe is broken and we
    // are already on our way out via the lifeline.
    let len = (payload.len() + 1) as u32;
    let _ = out.write_all(&len.to_be_bytes());
    let _ = out.write_all(&[ftype]);
    let _ = out.write_all(payload);
    let _ = out.flush();
}

fn fail(msg: &str) -> ! {
    let mut stdout = std::io::stdout();
    let body = serde_json::json!({ "message": msg }).to_string();
    write_frame(&mut stdout, F_ERROR, body.as_bytes());
    std::process::exit(1);
}

#[cfg(unix)]
fn signal_tree(pgid: u32, hard: bool) {
    let sig = if hard { libc::SIGKILL } else { libc::SIGTERM };
    unsafe {
        libc::killpg(pgid as libc::pid_t, sig);
    }
}

#[cfg(windows)]
struct JobGuard(win32job::Job);

#[cfg(windows)]
fn setup_job(pid: u32) -> Option<JobGuard> {
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_ALL_ACCESS};
    let job = win32job::Job::create().ok()?;
    let mut info = job.query_extended_limit_info().ok()?;
    info.limit_kill_on_job_close();
    job.set_extended_limit_info(&mut info).ok()?;
    let handle = unsafe { OpenProcess(PROCESS_ALL_ACCESS, 0, pid) };
    if handle.is_null() {
        return None;
    }
    job.assign_process(handle as isize).ok()?;
    Some(JobGuard(job))
}

#[cfg(windows)]
fn terminate_job(job: &Option<JobGuard>) {
    use windows_sys::Win32::System::JobObjects::TerminateJobObject;
    if let Some(JobGuard(job)) = job {
        unsafe {
            TerminateJobObject(job.handle() as _, 1);
        }
    }
}

fn main() {
    let mut stdin = std::io::stdin();
    let mut stdout = std::io::stdout();

    let first = match read_frame(&mut stdin) {
        Ok(f) => f,
        Err(_) => std::process::exit(0), // BEAM vanished before RUN
    };
    if first.first() != Some(&F_RUN) {
        fail("first frame must be RUN");
    }
    let cfg: RunCfg = match serde_json::from_slice(&first[1..]) {
        Ok(c) => c,
        Err(e) => fail(&format!("bad RUN frame: {e}")),
    };
    if cfg.argv.is_empty() {
        fail("argv must not be empty");
    }

    let pty = native_pty_system();
    let pair = match pty.openpty(PtySize {
        rows: cfg.rows.unwrap_or(24),
        cols: cfg.cols.unwrap_or(80),
        pixel_width: 0,
        pixel_height: 0,
    }) {
        Ok(p) => p,
        Err(e) => fail(&format!("openpty failed: {e}")),
    };

    let mut cmd = CommandBuilder::new(&cfg.argv[0]);
    cmd.args(&cfg.argv[1..]);
    if let Some(cwd) = &cfg.cwd {
        cmd.cwd(cwd);
    }
    for (k, v) in &cfg.env {
        cmd.env(k, v);
    }

    let mut child = match pair.slave.spawn_command(cmd) {
        Ok(c) => c,
        Err(e) => fail(&format!("spawn failed: {e}")),
    };
    drop(pair.slave);

    let pid = child.process_id().unwrap_or(0);
    #[cfg(windows)]
    let job = setup_job(pid);

    let (tx, rx) = mpsc::channel::<Event>();

    // PTY output reader
    let mut reader = pair
        .master
        .try_clone_reader()
        .unwrap_or_else(|e| fail(&format!("clone reader failed: {e}")));
    let tx_out = tx.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => {
                    let _ = tx_out.send(Event::ReaderEof);
                    break;
                }
                Ok(n) => {
                    if tx_out.send(Event::Output(buf[..n].to_vec())).is_err() {
                        break;
                    }
                }
            }
        }
    });

    // Child waiter
    let tx_wait = tx.clone();
    std::thread::spawn(move || {
        let code = child.wait().map(|s| s.exit_code()).unwrap_or(255);
        let _ = tx_wait.send(Event::ChildExited(code));
    });

    // Control frames from the BEAM; owns the pty writer for STDIN frames.
    let mut pty_writer = pair
        .master
        .take_writer()
        .unwrap_or_else(|e| fail(&format!("take writer failed: {e}")));
    let tx_ctl = tx;
    std::thread::spawn(move || loop {
        match read_frame(&mut stdin) {
            Err(_) => {
                let _ = tx_ctl.send(Event::StdinClosed);
                break;
            }
            Ok(frame) => match frame.split_first() {
                Some((&F_KILL, body)) => {
                    let grace = serde_json::from_slice::<KillCfg>(body)
                        .ok()
                        .and_then(|k| k.grace_ms)
                        .unwrap_or(5000);
                    let _ = tx_ctl.send(Event::Kill(grace));
                }
                Some((&F_STDIN, body)) => {
                    let _ = pty_writer.write_all(body);
                    let _ = pty_writer.flush();
                }
                Some((&F_RESIZE, body)) => {
                    if let Ok(r) = serde_json::from_slice::<ResizeCfg>(body) {
                        let _ = tx_ctl.send(Event::Resize(r.rows, r.cols));
                    }
                }
                _ => {} // unknown frame: ignore, forward compatibility
            },
        }
    });

    let max_head = cfg.max_output_bytes.unwrap_or(DEFAULT_MAX_OUTPUT);
    let mut head_sent: u64 = 0;
    let mut dropped: u64 = 0;
    let mut tail: VecDeque<u8> = VecDeque::with_capacity(TAIL_CAPACITY);

    let mut killed = false;
    let mut exit_code: Option<u32> = None;
    let mut reader_eof = false;
    let mut kill_deadline: Option<Instant> = None;
    let mut flush_deadline: Option<Instant> = None;

    loop {
        // Finish once the child is gone and output is flushed (or flush timed out).
        if let Some(code) = exit_code {
            let flushed =
                reader_eof || flush_deadline.map(|d| Instant::now() >= d).unwrap_or(false);
            if flushed {
                if dropped > 0 {
                    let (a, b) = tail.as_slices();
                    let mut t = Vec::with_capacity(a.len() + b.len());
                    t.extend_from_slice(a);
                    t.extend_from_slice(b);
                    write_frame(&mut stdout, F_TAIL, &t);
                }
                let msg = ExitMsg {
                    exit_code: code,
                    dropped_bytes: dropped,
                    killed,
                };
                write_frame(
                    &mut stdout,
                    F_EXIT,
                    serde_json::to_string(&msg).unwrap().as_bytes(),
                );
                std::process::exit(0);
            }
        }

        // Escalate to hard kill when the grace period lapses.
        if let Some(d) = kill_deadline {
            if Instant::now() >= d && exit_code.is_none() {
                #[cfg(unix)]
                signal_tree(pid, true);
                #[cfg(windows)]
                terminate_job(&job);
                kill_deadline = None;
            }
        }

        let next_deadline = [kill_deadline, flush_deadline]
            .into_iter()
            .flatten()
            .min()
            .map(|d| d.saturating_duration_since(Instant::now()))
            .unwrap_or(Duration::from_secs(3600));

        match rx.recv_timeout(next_deadline.max(Duration::from_millis(10))) {
            Ok(Event::Output(bytes)) => {
                let remaining = max_head.saturating_sub(head_sent) as usize;
                if remaining >= bytes.len() {
                    head_sent += bytes.len() as u64;
                    write_frame(&mut stdout, F_OUTPUT, &bytes);
                } else {
                    if remaining > 0 {
                        head_sent += remaining as u64;
                        write_frame(&mut stdout, F_OUTPUT, &bytes[..remaining]);
                    }
                    let overflow = &bytes[remaining..];
                    dropped += overflow.len() as u64;
                    for &b in overflow {
                        if tail.len() == TAIL_CAPACITY {
                            tail.pop_front();
                        }
                        tail.push_back(b);
                    }
                }
            }
            Ok(Event::ReaderEof) => reader_eof = true,
            Ok(Event::ChildExited(code)) => {
                exit_code = Some(code);
                flush_deadline = Some(Instant::now() + Duration::from_millis(FLUSH_AFTER_EXIT_MS));
            }
            Ok(Event::Kill(grace_ms)) => {
                killed = true;
                #[cfg(unix)]
                signal_tree(pid, false);
                #[cfg(windows)]
                {
                    // No portable soft-kill on Windows: Job termination is the kill.
                    let _ = grace_ms;
                    terminate_job(&job);
                }
                #[cfg(unix)]
                {
                    kill_deadline = Some(Instant::now() + Duration::from_millis(grace_ms));
                }
            }
            Ok(Event::Resize(rows, cols)) => {
                let _ = pair.master.resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                });
            }
            Ok(Event::StdinClosed) => {
                // Lifeline tripped: BEAM is gone. Kill the tree, then exit via
                // the normal path so children are reaped.
                killed = true;
                #[cfg(unix)]
                {
                    signal_tree(pid, false);
                    kill_deadline = Some(Instant::now() + Duration::from_millis(LIFELINE_GRACE_MS));
                }
                #[cfg(windows)]
                terminate_job(&job);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}
