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

import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
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

let TOOLS = new Map<string, ToolDef>();
let CWD = process.cwd();
let DIRS: string[] = [];
let reloadCounter = 0;

// One level deep: *.ts/*.js files, or subdir/index.ts (mirrors pi discovery).
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

async function loadAll(): Promise<{ tools: unknown[]; errors: unknown[] }> {
  TOOLS = new Map();
  const errors: unknown[] = [];
  // Cache-bust so edited files re-import (self-evolution reload).
  reloadCounter++;

  const pi: ExtensionAPI = {
    registerTool(def: ToolDef) {
      TOOLS.set(def.name, def);
    },
  };

  for (const dir of DIRS) {
    for (const file of await discover(dir)) {
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
    // fallthrough to report tools like reload does
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
