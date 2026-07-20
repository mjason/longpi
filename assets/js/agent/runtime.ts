import {
  type AppendMessage,
  type ThreadMessageLike,
  useExternalStoreRuntime,
} from "@assistant-ui/react";
import { useConversationChannel } from "./channel";
import type { ThreadItem } from "./types";

/**
 * Bridges our Phoenix Channel state into an assistant-ui ExternalStoreRuntime.
 *
 * ExternalStoreRuntime is the state adapter for backends that own their own
 * agent loop: it never calls an LLM, sends no requests, and runs no loop. The
 * agent loop lives entirely in Elixir. This only maps our channel thread items
 * to assistant-ui's message shape and forwards new user messages to the
 * channel.
 */
export function useChannelRuntime(conversationId: string) {
  const {
    items,
    status,
    send,
    interrupt,
    regenerate,
    respondApproval,
    runCommand,
    pendingApprovals,
    compactionCount,
    notices,
    usage,
  } = useConversationChannel(conversationId);

  const messages = itemsToMessages(items);

  const runtime = useExternalStoreRuntime({
    messages,
    isRunning: status === "running",
    onNew: async (message: AppendMessage) => {
      const text = message.content
        .filter((part): part is { type: "text"; text: string } => part.type === "text")
        .map((part) => part.text)
        .join("");
      const trimmed = text.trim();
      if (!trimmed) return;

      // Slash commands go to the command channel instead of being sent as a
      // message. Extensible: add cases as commands are added.
      if (trimmed.startsWith("/")) {
        const name = trimmed.slice(1).split(/\s+/)[0].toLowerCase();
        // Known or not, route to the command channel; the server replies
        // "unknown command" for anything it doesn't handle, shown as a notice.
        runCommand(name);
        return;
      }

      send(trimmed);
    },
    // The Reload action on an assistant message: re-run the last turn. The
    // server truncates back to the last user message and streams a fresh reply.
    onReload: async () => regenerate(),
    onCancel: async () => interrupt(),
    convertMessage: (message: ThreadMessageLike) => message,
  });

  return { runtime, pendingApprovals, respondApproval, compactionCount, notices, usage };
}

type AssistantPart = Extract<ThreadMessageLike["content"], readonly unknown[]>[number];

// Collapse our flat thread-item list into assistant-ui messages: consecutive
// assistant text and tool items belong to one assistant message, and tool
// results are attached to their originating tool-call part.
function itemsToMessages(items: ThreadItem[]): ThreadMessageLike[] {
  const messages: ThreadMessageLike[] = [];
  let assistantParts: AssistantPart[] | null = null;

  // Stable ids keyed by output position so assistant-ui reconciles messages
  // across streaming updates instead of treating each render as brand-new
  // (which duplicates text and can crash reconciliation).
  const flushAssistant = () => {
    if (assistantParts && assistantParts.length > 0) {
      messages.push({ id: `m-${messages.length}`, role: "assistant", content: assistantParts });
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
        });
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
          result: item.content !== undefined ? item.content : undefined,
          isError: item.error,
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
