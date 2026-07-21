// Bun extension host for longpi.
//
// The Elixir "brain" owns the agent loop; this Bun process owns extension
// module loading and tool execution, mirroring pi's extension model but split
// across an IPC boundary.
//
// Wire protocol: 4-byte big-endian length-prefixed JSON frames over stdin
// (from Elixir) and stdout (to Elixir). stdout is protocol-only — extension
// console output is redirected to stderr so it can't corrupt a frame.
//
//   Elixir -> host  {type:"load", cwd, dirs:[...], env:{NAME:value}}
//                   {type:"call", id, tool, args, env}     run a tool
//                   {type:"command", id, name, args}       run a slash command
//                   {type:"event", event, payload}         fire a lifecycle hook
//                   {type:"reload"}
//   host -> Elixir  {type:"ready", tools:[...], commands:[{name,description}], errors:[...]}
//                   {type:"result", id, ok, content}
//
// Extension sources, lowest precedence first (later wins on tool name):
//   1. packages   — deps in ~/.longpi/packages.json / <cwd>/.longpi/packages.json,
//                   installed with `bun install` and loaded via their package.json
//                   "longpi": { extensions: [...] } manifest.
//   2. global dir — ~/.longpi/extensions/
//   3. project dir — <cwd>/.longpi/extensions/  (wins conflicts, matching pi)

import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Keep stdout pristine: anything an extension logs goes to stderr.
for (const level of ["log", "info", "warn", "error", "debug"] as const) {
  console[level] = (...args: unknown[]) =>
    process.stderr.write(args.map((a) => (typeof a === "string" ? a : Bun.inspect(a))).join(" ") + "\n");
}

type ToolDef = {
  name: string;
  label?: string;
  description: string;
  parameters?: unknown; // JSON Schema object
  execute: (args: unknown, ctx: { cwd: string }) => unknown;
};

type CommandDef = {
  name: string;
  description: string;
  execute: (args: unknown, ctx: { cwd: string }) => unknown;
};

type EventHandler = (payload: unknown, ctx: { cwd: string }) => unknown;

/** The author-facing `longpi` API (an extension's default export is
 * `(longpi: LongpiAPI) => void | Promise<void>`). */
type LongpiAPI = {
  registerTool(def: ToolDef): void;
  registerCommand(name: string, def: Omit<CommandDef, "name">): void;
  on(event: string, handler: EventHandler): void;
};

type LoadError = { file: string; error: string };

let TOOLS = new Map<string, ToolDef>();
let COMMANDS = new Map<string, CommandDef>();
let HANDLERS = new Map<string, EventHandler[]>();
let CWD = process.cwd();
let DIRS: string[] = [];
let reloadCounter = 0;
// Names of env vars we injected from longpi's secret store last load, so a
// secret deleted in the UI is also removed from process.env on the next reload.
let MANAGED_ENV: string[] = [];

// Apply longpi's DB-stored secrets as process.env vars. Extensions read them
// via process.env.<NAME>; nothing touches the machine's real environment.
function applyEnv(env: unknown): void {
  for (const key of MANAGED_ENV) delete process.env[key];
  MANAGED_ENV = [];
  if (env && typeof env === "object") {
    for (const [key, value] of Object.entries(env as Record<string, unknown>)) {
      process.env[key] = String(value);
      MANAGED_ENV.push(key);
    }
  }
}

// --- discovery -------------------------------------------------------------

// A package.json with a "longpi": { extensions: [...] } manifest — the file
// paths are resolved relative to the package root. Returns null if not one.
async function readManifest(pkgRoot: string): Promise<string[] | null> {
  try {
    const pkg = JSON.parse(await readFile(join(pkgRoot, "package.json"), "utf8"));
    const exts = pkg?.longpi?.extensions;
    return Array.isArray(exts) ? exts.map((f: string) => resolve(pkgRoot, f)) : null;
  } catch {
    return null;
  }
}

// One level deep in an extensions dir: *.ts/*.js files, subdir/index.ts, or a
// subdir that is itself a package (package.json with a longpi manifest).
async function discover(dir: string): Promise<string[]> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return []; // missing dir is fine
  }
  const out: string[] = [];
  for (const entry of entries) {
    const path = join(dir, entry.name);
    if (entry.isFile() && /\.(ts|js|mjs)$/.test(entry.name)) {
      out.push(path);
    } else if (entry.isDirectory()) {
      const manifest = await readManifest(path);
      if (manifest) {
        out.push(...manifest);
        continue;
      }
      for (const index of ["index.ts", "index.js"]) {
        try {
          await stat(join(path, index));
          out.push(join(path, index));
          break;
        } catch {
          // no index here
        }
      }
    }
  }
  return out;
}

// --- packages (bun install) ------------------------------------------------

type PackagesConfig = { config: string; managed: string };

function packageScopes(): PackagesConfig[] {
  // Global first, project last, so project packages win on name.
  return [
    { config: join(homedir(), ".longpi", "packages.json"), managed: join(homedir(), ".longpi", "packages") },
    { config: join(CWD, ".longpi", "packages.json"), managed: join(CWD, ".longpi", "packages") },
  ];
}

async function readPackagesConfig(path: string): Promise<Record<string, string> | null> {
  try {
    const json = JSON.parse(await readFile(path, "utf8"));
    const packages = json?.packages;
    return packages && typeof packages === "object" ? packages : null;
  } catch {
    return null; // missing/invalid config = no packages
  }
}

// Install the configured deps into `managed` with Bun, but only when they
// changed (or node_modules is absent) so warm reloads stay fast and offline.
async function ensureInstalled(managed: string, deps: Record<string, string>): Promise<void> {
  await mkdir(managed, { recursive: true });
  const manifestPath = join(managed, "package.json");
  const desired = { name: "longpi-managed-packages", private: true, dependencies: deps };

  let needsInstall = false;
  try {
    const existing = JSON.parse(await readFile(manifestPath, "utf8"));
    needsInstall = JSON.stringify(existing.dependencies ?? {}) !== JSON.stringify(deps);
  } catch {
    needsInstall = true;
  }
  try {
    await stat(join(managed, "node_modules"));
  } catch {
    needsInstall = true;
  }

  if (!needsInstall) return;

  await writeFile(manifestPath, JSON.stringify(desired, null, 2));
  // Use the same bun that's running this host.
  const proc = Bun.spawn([process.execPath, "install", "--no-save"], {
    cwd: managed,
    stdout: "pipe",
    stderr: "pipe",
  });
  if ((await proc.exited) !== 0) {
    throw new Error(`bun install failed: ${await new Response(proc.stderr).text()}`);
  }
}

async function loadPackages(errors: LoadError[]): Promise<string[]> {
  const files: string[] = [];
  for (const scope of packageScopes()) {
    const deps = await readPackagesConfig(scope.config);
    if (!deps || Object.keys(deps).length === 0) continue;
    try {
      await ensureInstalled(scope.managed, deps);
      for (const name of Object.keys(deps)) {
        const pkgRoot = join(scope.managed, "node_modules", name);
        const manifest = await readManifest(pkgRoot);
        if (manifest) files.push(...manifest);
        else errors.push({ file: name, error: `package "${name}" has no "longpi.extensions" manifest` });
      }
    } catch (err) {
      errors.push({ file: scope.config, error: err instanceof Error ? err.message : String(err) });
    }
  }
  return files;
}

// --- load / execute --------------------------------------------------------

async function loadAll(): Promise<{ tools: unknown[]; commands: unknown[]; errors: LoadError[] }> {
  TOOLS = new Map();
  COMMANDS = new Map();
  HANDLERS = new Map();
  const errors: LoadError[] = [];
  // Cache-bust so edited files re-import (self-evolution reload).
  reloadCounter++;

  const longpi: LongpiAPI = {
    registerTool(def: ToolDef) {
      TOOLS.set(def.name, def);
    },
    registerCommand(name: string, def: Omit<CommandDef, "name">) {
      COMMANDS.set(name, { name, ...def });
    },
    on(event: string, handler: EventHandler) {
      const list = HANDLERS.get(event) ?? [];
      list.push(handler);
      HANDLERS.set(event, list);
    },
  };

  // Order = precedence (last import wins on name): packages, then global, then project.
  const files = await loadPackages(errors);
  for (const dir of DIRS) files.push(...(await discover(dir)));

  for (const file of files) {
    try {
      const url = pathToFileURL(file).href + "?v=" + reloadCounter;
      const mod = await import(url);
      if (typeof mod.default !== "function") {
        errors.push({ file, error: "extension has no default-exported factory function" });
        continue;
      }
      await mod.default(longpi);
    } catch (err) {
      errors.push({ file, error: err instanceof Error ? (err.stack ?? err.message) : String(err) });
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

function toText(result: unknown): string {
  if (result == null) return "";
  if (typeof result === "string") return result;
  const content = (result as { content?: unknown }).content;
  if (Array.isArray(content)) {
    return content
      .filter((c) => c && (c as { type?: string }).type === "text")
      .map((c) => (c as { text?: string }).text ?? "")
      .join("");
  }
  return typeof result === "object" ? JSON.stringify(result) : String(result);
}

async function callTool(tool: string, args: unknown): Promise<{ ok: boolean; content: string }> {
  const def = TOOLS.get(tool);
  if (!def) return { ok: false, content: `unknown extension tool: ${tool}` };
  try {
    return { ok: true, content: toText(await def.execute(args, { cwd: CWD })) };
  } catch (err) {
    return { ok: false, content: err instanceof Error ? err.message : String(err) };
  }
}

async function callCommand(name: string, args: unknown): Promise<{ ok: boolean; content: string }> {
  const def = COMMANDS.get(name);
  if (!def) return { ok: false, content: `unknown extension command: ${name}` };
  try {
    return { ok: true, content: toText(await def.execute(args, { cwd: CWD })) };
  } catch (err) {
    return { ok: false, content: err instanceof Error ? err.message : String(err) };
  }
}

// Lifecycle hooks are fire-and-forget: run every handler, swallow failures.
async function fireEvent(event: string, payload: unknown): Promise<void> {
  for (const handler of HANDLERS.get(event) ?? []) {
    try {
      await handler(payload, { cwd: CWD });
    } catch (err) {
      process.stderr.write(`extension "${event}" handler error: ${String(err)}\n`);
    }
  }
}

// --- framing ---------------------------------------------------------------

function writeFrame(obj: unknown): void {
  const payload = Buffer.from(JSON.stringify(obj));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  process.stdout.write(Buffer.concat([header, payload]));
}

async function handle(msg: { type: string; [k: string]: unknown }): Promise<void> {
  switch (msg.type) {
    case "load":
      CWD = (msg.cwd as string) || process.cwd();
      DIRS = (msg.dirs as string[]) || [];
    // fallthrough: report tools like reload does
    case "reload": {
      applyEnv(msg.env);
      const { tools, commands, errors } = await loadAll();
      writeFrame({ type: "ready", tools, commands, errors });
      break;
    }
    case "call": {
      // Secrets are re-injected on every call so a key edited in the UI takes
      // effect immediately, with no reload.
      applyEnv(msg.env);
      const { ok, content } = await callTool(msg.tool as string, msg.args ?? {});
      writeFrame({ type: "result", id: msg.id, ok, content });
      break;
    }
    case "command": {
      const { ok, content } = await callCommand(msg.name as string, msg.args ?? {});
      writeFrame({ type: "result", id: msg.id, ok, content });
      break;
    }
    case "event":
      await fireEvent(msg.event as string, msg.payload);
      break;
  }
}

// Frame reader: accumulate stdin, dispatch each complete 4-byte-prefixed frame.
let buf = Buffer.alloc(0);
for await (const chunk of Bun.stdin.stream()) {
  buf = Buffer.concat([buf, Buffer.from(chunk)]);
  while (buf.length >= 4) {
    const len = buf.readUInt32BE(0);
    if (buf.length < 4 + len) break;
    const payload = buf.subarray(4, 4 + len);
    buf = buf.subarray(4 + len);
    try {
      await handle(JSON.parse(payload.toString()));
    } catch (err) {
      process.stderr.write("host frame error: " + String(err) + "\n");
    }
  }
}
