import { cn } from "@/lib/utils";

/** Tools whose args describe a file change we can render as a diff. */
export function isDiffTool(toolName: string): boolean {
  return toolName === "edit" || toolName === "write";
}

const CONTEXT_LINES = 2;
const MAX_WRITE_LINES = 60;

type Row = { kind: "context" | "add" | "del"; text: string };

// A line-level diff of an exact old->new replacement: strips the common leading
// and trailing lines, keeps a little context around the change. Not a full LCS
// diff, but edit's semantics are "replace this exact block with that", so a
// removed block followed by an added block reads true.
function diffRows(oldStr: string, newStr: string): Row[] {
  const o = oldStr.split("\n");
  const n = newStr.split("\n");

  let start = 0;
  while (start < o.length && start < n.length && o[start] === n[start]) start++;

  let endO = o.length;
  let endN = n.length;
  while (endO > start && endN > start && o[endO - 1] === n[endN - 1]) {
    endO--;
    endN--;
  }

  const preFrom = Math.max(0, start - CONTEXT_LINES);
  const rows: Row[] = [];
  for (let i = preFrom; i < start; i++) rows.push({ kind: "context", text: o[i] });
  for (let i = start; i < endO; i++) rows.push({ kind: "del", text: o[i] });
  for (let i = start; i < endN; i++) rows.push({ kind: "add", text: n[i] });
  for (let i = endO; i < Math.min(o.length, endO + CONTEXT_LINES); i++)
    rows.push({ kind: "context", text: o[i] });
  return rows;
}

function writeRows(content: string): { rows: Row[]; extra: number } {
  const lines = content.split("\n");
  const shown = lines.slice(0, MAX_WRITE_LINES);
  return {
    rows: shown.map((text) => ({ kind: "add", text })),
    extra: Math.max(0, lines.length - shown.length),
  };
}

const PREFIX: Record<Row["kind"], string> = { context: " ", add: "+", del: "-" };

function DiffBody({ rows, footer }: { rows: Row[]; footer?: string }) {
  return (
    <pre className="overflow-x-auto rounded-md bg-muted/50 p-2.5 text-xs leading-relaxed">
      {rows.map((row, i) => (
        <div
          key={i}
          className={cn(
            "px-1",
            row.kind === "add" && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
            row.kind === "del" && "bg-red-500/10 text-red-700 dark:text-red-300",
            row.kind === "context" && "text-muted-foreground",
          )}
        >
          <span aria-hidden className="mr-2 select-none opacity-60">
            {PREFIX[row.kind]}
          </span>
          {row.text || " "}
        </div>
      ))}
      {footer && <div className="px-1 pt-1 text-muted-foreground">{footer}</div>}
    </pre>
  );
}

/**
 * Renders edit/write tool args as a colored diff. Falls back to null when the
 * expected fields are missing (the caller then shows the raw args instead).
 */
export function ToolDiff({
  toolName,
  args,
}: {
  toolName: string;
  args: Record<string, unknown> | undefined;
}) {
  if (!args) return null;
  const path = typeof args.path === "string" ? args.path : null;

  if (toolName === "edit") {
    const oldStr = args.old_string;
    const newStr = args.new_string;
    if (typeof oldStr !== "string" || typeof newStr !== "string") return null;
    return (
      <div className="flex flex-col gap-1">
        {path && <DiffPath path={path} />}
        <DiffBody rows={diffRows(oldStr, newStr)} />
      </div>
    );
  }

  if (toolName === "write") {
    const content = args.content;
    if (typeof content !== "string") return null;
    const { rows, extra } = writeRows(content);
    return (
      <div className="flex flex-col gap-1">
        {path && <DiffPath path={path} label="new file" />}
        <DiffBody rows={rows} footer={extra > 0 ? `… ${extra} more line${extra === 1 ? "" : "s"}` : undefined} />
      </div>
    );
  }

  return null;
}

function DiffPath({ path, label }: { path: string; label?: string }) {
  return (
    <div className="flex items-center gap-2">
      <span className="font-mono text-xs text-foreground/80">{path}</span>
      {label && (
        <span className="rounded bg-emerald-500/15 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700 dark:text-emerald-300">
          {label}
        </span>
      )}
    </div>
  );
}
