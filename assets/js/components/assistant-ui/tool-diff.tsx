import { DiffViewer } from "@/components/assistant-ui/diff-viewer";

/** Tools whose args describe a file change we can render as a diff. */
export function isDiffTool(toolName: string): boolean {
  return toolName === "edit" || toolName === "write";
}

/**
 * Renders edit/write tool args as a diff using assistant-ui's DiffViewer.
 *
 * The change is already in the tool-call args (edit: old_string/new_string;
 * write: content), so this is a pure client-side render — no backend round-trip
 * and it survives reload since args are persisted on the assistant message.
 *
 * For edit we diff the replaced fragment (old vs new); for write we diff an
 * empty file against the new content, so it reads as an added file.
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
      <DiffViewer
        oldFile={{ content: oldStr, name: path }}
        newFile={{ content: newStr, name: path }}
        variant="muted"
        size="sm"
      />
    );
  }

  if (toolName === "write") {
    const content = args.content;
    if (typeof content !== "string") return null;
    return (
      <DiffViewer
        oldFile={{ content: "", name: path }}
        newFile={{ content, name: path }}
        variant="muted"
        size="sm"
      />
    );
  }

  return null;
}
