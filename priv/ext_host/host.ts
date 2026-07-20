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
//   Elixir -> host  {type:"load", cwd, dirs:[...]}
//                   {type:"call", id, tool, args}
//                   {type:"reload"}
//   host -> Elixir  {type:"ready", tools:[{name,description,parameters}], errors:[...]}
//                   {type:"result", id, ok, content}
//
// Extension sources, lowest precedence first (later wins on tool name):
//   1. packages   — deps in ~/.longpi/packages.json / <cwd>/.longpi/packages.json,
//                   installed with `bun install` and loaded via their package.json
//                   "pi": { extensions: [...] } manifest.
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

/** The author-facing `pi` API. MVP surface: registerTool only. */
type ExtensionAPI = { registerTool(def: ToolDef): void };

type LoadError = { file: string; error: string };

let TOOLS = new Map<string, ToolDef>();
let CWD = process.cwd();
let DIRS: string[] = [];
let reloadCounter = 0;

// --- discovery -------------------------------------------------------------

// A package.json with a "pi": { extensions: [...] } manifest — the file paths
// are resolved relative to the package root. Returns null if not a longpi pkg.
async function readManifest(pkgRoot: string): Promise<string[] | null> {
  try {
    const pkg = JSON.parse(await readFile(join(pkgRoot, "package.json"), "utf8"));
    const exts = pkg?.pi?.extensions;
    return Array.isArray(exts) ? exts.map((f: string) => resolve(pkgRoot, f)) : null;
  } catch {
    return null;
  }
}

// One level deep in an extensions dir: *.ts/*.js files, subdir/index.ts, or a
// subdir that is itself a package (package.json with a pi manifest).
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
        else errors.push({ file: name, error: `package "${name}" has no "pi.extensions" manifest` });
      }
    } catch (err) {
      errors.push({ file: scope.config, error: err instanceof Error ? err.message : String(err) });
    }
  }
  return files;
}

// --- load / execute --------------------------------------------------------

async function loadAll(): Promise<{ tools: unknown[]; errors: LoadError[] }> {
  TOOLS = new Map();
  const errors: LoadError[] = [];
  // Cache-bust so edited files re-import (self-evolution reload).
  reloadCounter++;

  const pi: ExtensionAPI = {
    registerTool(def: ToolDef) {
      TOOLS.set(def.name, def);
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
      await mod.default(pi);
    } catch (err) {
      errors.push({ file, error: err instanceof Error ? (err.stack ?? err.message) : String(err) });
    }
  }

  const tools = [...TOOLS.values()].map((t) => ({
    name: t.name,
    description: t.description,
    parameters: t.parameters ?? { type: "object", properties: {} },
  }));
  return { tools, errors };
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
      const { tools, errors } = await loadAll();
      writeFrame({ type: "ready", tools, errors });
      break;
    }
    case "call": {
      const { ok, content } = await callTool(msg.tool as string, msg.args ?? {});
      writeFrame({ type: "result", id: msg.id, ok, content });
      break;
    }
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
