import { useState } from "react";

import { DiffViewer } from "@/components/assistant-ui/diff-viewer";
import { cn } from "@/lib/utils";

/** Tools whose args describe a file change we can render as a diff. */
export function isDiffTool(toolName: string): boolean {
  return toolName === "edit" || toolName === "write" || toolName === "apply_patch";
}

/** Above this many diff lines, collapse to a capped height with a "show all". */
const COLLAPSE_AT = 20;

function countLines(text: string): number {
  return text === "" ? 0 : text.split("\n").length;
}

/**
 * Caps a tall diff at a fixed height with a fade + "Show all N lines" toggle, so
 * a 200-line write doesn't flood the transcript. Short diffs render untouched.
 */
function CollapsibleDiff({ lines, children }: { lines: number; children: React.ReactNode }) {
  const [expanded, setExpanded] = useState(false);
  if (lines <= COLLAPSE_AT) return <>{children}</>;

  return (
    <div>
      <div className={cn("relative", !expanded && "max-h-80 overflow-hidden")}>
        {children}
        {!expanded && (
          <div className="from-background pointer-events-none absolute inset-x-0 bottom-0 h-16 bg-gradient-to-t to-transparent" />
        )}
      </div>
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="text-muted-foreground hover:text-foreground mt-1 rounded text-xs outline-none focus-visible:ring-2 focus-visible:ring-ring/35"
      >
        {expanded ? "Show less" : `Show all ${lines} lines`}
      </button>
    </div>
  );
}

/** Renders raw patch text with +/- lines coloured, for the apply_patch tool. */
function PatchView({ text }: { text: string }) {
  return (
    <pre className="bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs leading-relaxed">
      <code>
        {text.split("\n").map((line, i) => (
          <div
            key={i}
            className={cn(
              "px-1",
              line.startsWith("+") && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
              line.startsWith("-") && "bg-red-500/10 text-red-700 dark:text-red-300",
              (line.startsWith("@@") || line.startsWith("***")) && "text-muted-foreground",
            )}
          >
            {line || " "}
          </div>
        ))}
      </code>
    </pre>
  );
}

/**
 * Renders edit/write/apply_patch tool args as a diff.
 *
 * The change is already in the tool-call args (edit: old_string/new_string;
 * write: content; apply_patch: input), so this is a pure client-side render —
 * no backend round-trip and it survives reload since args are persisted on the
 * assistant message. Tall diffs collapse to a capped height.
 */
export function ToolDiff({
  toolName,
  args,
}: {
  toolName: string;
  args: Record<string, unknown> | undefined;
}) {
  if (!args) return null;
  const path = typeof args.path === "string" ? args.path : undefined;

  if (toolName === "edit") {
    const oldStr = args.old_string;
    const newStr = args.new_string;
    if (typeof oldStr !== "string" || typeof newStr !== "string") return null;
    return (
      <CollapsibleDiff lines={countLines(oldStr) + countLines(newStr)}>
        <DiffViewer
          oldFile={{ content: oldStr, name: path }}
          newFile={{ content: newStr, name: path }}
          variant="muted"
          size="sm"
        />
      </CollapsibleDiff>
    );
  }

  if (toolName === "write") {
    const content = args.content;
    if (typeof content !== "string") return null;
    return (
      <CollapsibleDiff lines={countLines(content)}>
        <DiffViewer
          oldFile={{ content: "", name: path }}
          newFile={{ content, name: path }}
          variant="muted"
          size="sm"
        />
      </CollapsibleDiff>
    );
  }

  if (toolName === "apply_patch") {
    const input = args.input;
    if (typeof input !== "string") return null;
    return (
      <CollapsibleDiff lines={countLines(input)}>
        <PatchView text={input} />
      </CollapsibleDiff>
    );
  }

  return null;
}
