// Nicer result rendering for a few built-in tools — a terminal for bash, a
// file listing for ls — instead of a plain text dump. We control the frontend
// for built-ins, so these are hand-written React (unlike extension tools, which
// ship a serializable UI tree; see ExtensionUI).

import type { ReactNode } from "react";
import { File, Folder } from "lucide-react";

import { cn } from "../lib/utils";

/** A custom result view for a built-in tool, or null to use the default. */
export function renderBuiltinResult(toolName: string, result: unknown): ReactNode | null {
  if (typeof result !== "string") return null;
  switch (toolName) {
    case "bash":
      return <BashResult text={result} />;
    case "ls":
      return <LsResult text={result} />;
    default:
      return null;
  }
}

// Split a tool result into its body and the trailing "(…)" footnotes the
// built-ins append (exit code, timeout, truncation).
function splitNotes(text: string): { body: string; notes: string[] } {
  const lines = text.split("\n");
  const notes: string[] = [];
  while (lines.length > 0) {
    const last = lines[lines.length - 1].trim();
    if (last.startsWith("(") && last.endsWith(")")) {
      notes.unshift(last.slice(1, -1));
      lines.pop();
    } else {
      break;
    }
  }
  return { body: lines.join("\n"), notes };
}

function BashResult({ text }: { text: string }) {
  const { body, notes } = splitNotes(text);
  const failed = notes.some((n) => /exit code: [1-9]/.test(n) || n.includes("timed out"));

  return (
    <div className="mt-1 space-y-1.5">
      <pre className="overflow-x-auto rounded-md bg-zinc-900 p-3 font-mono text-xs leading-relaxed text-zinc-100 dark:bg-zinc-950">
        <code>{body === "" ? "(no output)" : body}</code>
      </pre>
      {notes.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {notes.map((note, i) => (
            <span
              key={i}
              className={cn(
                "rounded px-1.5 py-0.5 text-[11px] ring-1 ring-black/[0.06] dark:ring-white/[0.08]",
                failed ? "text-red-600 dark:text-red-400" : "text-muted-foreground",
              )}
            >
              {note}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function LsResult({ text }: { text: string }) {
  const lines = text.split("\n").filter((l) => l !== "");
  const note = lines.find((l) => l.startsWith("[") && l.endsWith("]"));
  const entries = lines.filter((l) => l !== note && l !== "(empty directory)");

  if (entries.length === 0) {
    return <p className="mt-1 text-xs text-muted-foreground">{text}</p>;
  }

  return (
    <div className="mt-1 space-y-1.5">
      <div className="grid grid-cols-2 gap-x-4 gap-y-0.5 sm:grid-cols-3">
        {entries.map((entry, i) => {
          const isDir = entry.endsWith("/");
          const name = isDir ? entry.slice(0, -1) : entry;
          return (
            <div key={i} className="flex items-center gap-1.5 text-xs">
              {isDir ? (
                <Folder className="size-3.5 shrink-0 text-blue-500" />
              ) : (
                <File className="size-3.5 shrink-0 text-muted-foreground" />
              )}
              <span className={cn("truncate", isDir && "font-medium text-foreground")}>{name}</span>
            </div>
          );
        })}
      </div>
      {note && <p className="text-[11px] text-muted-foreground">{note.slice(1, -1)}</p>}
    </div>
  );
}
