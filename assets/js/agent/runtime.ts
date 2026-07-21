import {
  type AppendMessage,
  CompositeAttachmentAdapter,
  type ExternalStoreThreadListAdapter,
  SimpleImageAttachmentAdapter,
  SimpleTextAttachmentAdapter,
  type ThreadMessageLike,
  useExternalStoreRuntime,
} from "@assistant-ui/react";
import { createContext } from "react";
import { useConversationChannel } from "./channel";
import { slashCommandHelp } from "./slashCommands";
import type { MessageAttachment, ThreadItem } from "./types";

/**
 * Re-run the last turn. Exposed via context (not assistant-ui's Reload action)
 * because our backend truncates the last turn and streams a fresh reply in
 * place — it does not keep the old response as a switchable branch. Wiring it
 * through assistant-ui's reload would spawn a phantom "2/2" branch that can't
 * be navigated (the old tool history is already gone server-side).
 */
export const RegenerateContext = createContext<(() => void) | null>(null);

// Official assistant-ui adapters power the composer's attach button: images are
// encoded to base64 data URLs for the vision model, text files inlined as text.
// Stateless, so one shared instance is fine.
const attachmentAdapter = new CompositeAttachmentAdapter([
  new SimpleImageAttachmentAdapter(),
  new SimpleTextAttachmentAdapter(),
]);

/** Pull our wire-format attachments out of an assistant-ui AppendMessage. */
export function extractAttachments(message: AppendMessage): MessageAttachment[] {
  const out: MessageAttachment[] = [];
  for (const attachment of message.attachments ?? []) {
    for (const part of attachment.content ?? []) {
      if (part.type === "image") {
        const match = /^data:([^;]+);base64,(.*)$/s.exec(part.image);
        if (match) out.push({ type: "image", name: attachment.name, media_type: match[1], data: match[2] });
      } else if (part.type === "text") {
        out.push({ type: "file", name: attachment.name, text: part.text });
      }
    }
  }
  return out;
}

/** Rebuild an assistant-ui attachment (for rendering a sent user message) from
 * our wire format. Images show a thumbnail; text files a document tile. */
export function toUiAttachments(attachments: MessageAttachment[]) {
  return attachments.map((attachment, index) =>
    attachment.type === "image"
      ? {
          id: `att-${index}`,
          type: "image" as const,
          name: attachment.name,
          contentType: attachment.media_type,
          content: [
            {
              type: "image" as const,
              image: `data:${attachment.media_type};base64,${attachment.data}`,
            },
          ],
          status: { type: "complete" as const },
        }
      : {
          id: `att-${index}`,
          type: "document" as const,
          name: attachment.name,
          contentType: "text/plain",
          content: [{ type: "text" as const, text: attachment.text }],
          status: { type: "complete" as const },
        },
  );
}

/**
 * Bridges our Phoenix Channel state into an assistant-ui ExternalStoreRuntime.
 *
 * ExternalStoreRuntime is the state adapter for backends that own their own
 * agent loop: it never calls an LLM, sends no requests, and runs no loop. The
 * agent loop lives entirely in Elixir. This only maps our channel thread items
 * to assistant-ui's message shape and forwards new user messages to the
 * channel.
 */
export function useChannelRuntime(
  conversationId: string,
  defaultModel: string,
  // Optional thread list (assistant-ui's ThreadList component reads it) — the
  // embed view uses this for per-workspace conversation switching.
  threadList?: ExternalStoreThreadListAdapter,
) {
  const {
    items,
    status,
    send,
    interrupt,
    regenerate,
    respondApproval,
    runCommand,
    setModel,
    setReasoning,
    showNotice,
    pendingApprovals,
    compactionCount,
    notices,
    usage,
    model,
    reasoningEffort,
    title,
    commands,
  } = useConversationChannel(conversationId);

  const currentModel = model ?? defaultModel;

  const messages = itemsToMessages(items);

  const runtime = useExternalStoreRuntime({
    messages,
    isRunning: status === "running",
    adapters: { attachments: attachmentAdapter, ...(threadList ? { threadList } : {}) },
    onNew: async (message: AppendMessage) => {
      const text = message.content
        .filter((part): part is { type: "text"; text: string } => part.type === "text")
        .map((part) => part.text)
        .join("");
      const trimmed = text.trim();
      const attachments = extractAttachments(message);
      if (!trimmed && attachments.length === 0) return;

      // Slash commands go to the command channel instead of being sent as a
      // message. Extensible: add cases as commands are added.
      if (trimmed.startsWith("/")) {
        const [rawName, ...rest] = trimmed.slice(1).split(/\s+/);
        const name = rawName.toLowerCase();
        const arg = rest.join(" ").trim();

        if (name === "help") {
          showNotice("info", slashCommandHelp());
          return;
        }
        if (name === "model") {
          if (arg) setModel(arg);
          else showNotice("info", `Current model: ${currentModel}`);
          return;
        }
        // compact, extension commands, and anything else route to the command
        // channel; the server replies "unknown command" for what it doesn't
        // handle, or the command's output text (shown as a notice).
        runCommand(name, arg);
        return;
      }

      send(trimmed, attachments);
    },
    // No onReload: regenerate is exposed via RegenerateContext instead, so it
    // replaces the last turn in place rather than creating a branch we can't
    // support (see RegenerateContext).
    onCancel: async () => interrupt(),
    // Native in-message tool approval: ToolFallback's Allow/Deny routes here.
    onRespondToToolApproval: ({ approvalId, approved }) =>
      respondApproval(approvalId, approved ?? false),
    convertMessage: (message: ThreadMessageLike) => message,
  });

  return {
    runtime,
    compactionCount,
    notices,
    usage,
    currentModel,
    setModel,
    reasoningEffort,
    setReasoning,
    title,
    commands,
    regenerate,
  };
}

type AssistantPart = Extract<ThreadMessageLike["content"], readonly unknown[]>[number];

// Collapse our flat thread-item list into assistant-ui messages: consecutive
// assistant text and tool items belong to one assistant message, and tool
// results are attached to their originating tool-call part.
export function itemsToMessages(items: ThreadItem[]): ThreadMessageLike[] {
  const messages: ThreadMessageLike[] = [];
  let assistantParts: AssistantPart[] | null = null;

  // Stable ids keyed by output position so assistant-ui reconciles messages
  // across streaming updates instead of treating each render as brand-new
  // (which duplicates text and can crash reconciliation).
  const flushAssistant = () => {
    if (assistantParts && assistantParts.length > 0) {
      // A result-less tool-call part inherits the message status, so a pending
      // approval only surfaces as "requires-action" (which ToolFallback renders
      // as Allow/Deny) when the message itself carries that status.
      const awaitingApproval = assistantParts.some(
        (part) => part.type === "tool-call" && part.approval != null,
      );
      messages.push({
        id: `m-${messages.length}`,
        role: "assistant",
        content: assistantParts,
        ...(awaitingApproval
          ? { status: { type: "requires-action" as const, reason: "tool-calls" as const } }
          : {}),
      });
    }
    assistantParts = null;
  };

  for (const item of items) {
    switch (item.kind) {
      case "user":
        flushAssistant();
        messages.push({
          id: `m-${messages.length}`,
          role: "user",
          content: [{ type: "text", text: item.text }],
          ...(item.attachments?.length
            ? { attachments: toUiAttachments(item.attachments) }
            : {}),
        });
        break;

      case "reasoning":
        assistantParts ??= [];
        if (item.text) assistantParts.push({ type: "reasoning", text: item.text });
        break;

      case "assistant":
        assistantParts ??= [];
        if (item.text) assistantParts.push({ type: "text", text: item.text });
        break;

      case "tool":
        assistantParts ??= [];
        assistantParts.push({
          type: "tool-call",
          toolCallId: item.id,
          toolName: item.name,
          // args originate from JSON, so they are valid JSON values.
          args: (item.args ?? {}) as Record<string, never>,
          argsText: JSON.stringify(item.args ?? {}),
          // Final result once done; while running, show the live streamed output
          // so long commands report progress instead of a bare spinner.
          result: item.content !== undefined ? item.content : item.output,
          isError: item.error,
          // While awaiting approval, expose it as a native tool-approval gate so
          // ToolFallback renders inline Allow/Deny (id = the tool-call id, which
          // the backend keys permission responses by).
          ...(item.awaitingApproval ? { approval: { id: item.id } } : {}),
        });
        break;

      case "notice":
        // Notices are transient UI hints; assistant-ui has no slot for them.
        break;
    }
  }

  flushAssistant();
  return messages;
}
