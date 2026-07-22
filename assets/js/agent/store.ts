import { Channel } from "phoenix";
import { createContext, useContext } from "react";
import { createStore, useStore } from "zustand";

import {
  type ConversationAction,
  type ConversationChannelState,
  type ContextUsage,
  type ExtCommand,
  reduce,
  type SubagentInfo,
} from "./channel";
import type { MessageAttachment, SessionStatus, ThreadItem } from "./types";

/**
 * The single source of truth for one conversation's live UI state.
 *
 * Before this store, the same state was split across a `useReducer` in
 * `useConversationChannel` plus eight React contexts wired down a
 * Provider pyramid, plus scattered component state. That fragmentation is why
 * a page reload lost in-flight information and why every new shared value
 * needed its own context. Now everything a conversation view needs — the
 * thread items, status, model/reasoning/usage/title, extension commands,
 * subagents, the workspace (cwd + files), and every action — lives in one
 * zustand store, created per conversation and provided once.
 *
 * Components read slices with `useConversationStore(s => s.model)`, so only the
 * subscribers of a changed slice re-render (unlike context, which re-renders
 * every consumer). The channel event handlers drive the store through
 * `apply(action)`, which reuses the existing (well-tested) `reduce`.
 */
export type ConversationState = ConversationChannelState & {
  // The conversation's own model; `model` (above) is a live override, null =
  // use this. Set by the host at mount. `selectCurrentModel` resolves them.
  defaultModel: string;
  setDefaultModel: (model: string) => void;

  // ── Workspace (was WorkspaceCwdContext / WorkspaceFilesContext) ──
  cwd: string;
  workspaceFiles: string[];
  setWorkspace: (cwd: string, files: string[]) => void;

  // ── Fork (was ForkContext): host-specific (navigate vs switch-in-place),
  //    so the host injects the handler; defaults to a no-op. ──
  fork: (position: number, prefill?: string) => void;
  setFork: (fork: (position: number, prefill?: string) => void) => void;

  // ── Channel plumbing ──
  bindChannel: (channel: Channel | null) => void;
  // Apply a channel event through the shared reducer.
  apply: (action: ConversationAction) => void;

  // ── Actions (were the useConversationChannel closures) ──
  send: (text: string, attachments?: MessageAttachment[]) => void;
  interrupt: () => void;
  regenerate: () => void;
  editLast: (text: string, attachments?: MessageAttachment[]) => void;
  respondApproval: (id: string, approved: boolean) => void;
  runCommand: (name: string, arg?: string) => void;
  setModel: (spec: string) => void;
  setReasoning: (effort: string | null) => void;
  showNotice: (tone: "error" | "info", text: string) => void;
};

const INITIAL: ConversationChannelState = {
  items: [],
  status: "connecting" as SessionStatus,
  usage: null,
  model: null,
  reasoningEffort: null,
  title: null,
  commands: [],
  subagents: {},
  subagentApprovals: {},
};

export type ConversationStore = ReturnType<typeof createConversationStore>;

export function createConversationStore() {
  let channel: Channel | null = null;

  return createStore<ConversationState>((set, get) => {
    const apply = (action: ConversationAction) => set((s) => reduce(s, action));

    // Push to the channel; route an error reply to a notice. `busyText` gives a
    // friendlier message for the "agent is still working" case.
    const push = (
      event: string,
      payload: object,
      onError?: (reason: string) => string,
    ) => {
      channel
        ?.push(event, payload)
        .receive("error", (reply: { reason: string }) =>
          apply({
            type: "notice",
            tone: "error",
            text: onError ? onError(reply.reason) : reply.reason,
          }),
        );
    };

    return {
      ...INITIAL,

      defaultModel: "",
      setDefaultModel: (defaultModel) => set({ defaultModel }),

      cwd: "",
      workspaceFiles: [],
      setWorkspace: (cwd, files) => set({ cwd, workspaceFiles: files }),

      fork: () => {},
      setFork: (fork) => set({ fork }),

      bindChannel: (next) => {
        channel = next;
      },
      apply,

      send: (text, attachments = []) => {
        apply({ type: "user_sent", text, attachments });
        push("send_message", { text, attachments }, (reason) =>
          reason === "busy"
            ? "The agent is still working - interrupt it first."
            : reason,
        );
      },

      interrupt: () => {
        channel?.push("interrupt", {});
      },

      regenerate: () => push("regenerate", {}),

      editLast: (text, attachments = []) => push("edit_last", { text, attachments }),

      respondApproval: (id, approved) => {
        channel?.push("permission_response", { id, approved });
      },

      runCommand: (name, arg = "") => {
        channel
          ?.push("command", { name, arg })
          .receive("ok", (reply: { content?: string }) => {
            if (reply?.content) apply({ type: "notice", tone: "info", text: reply.content });
          })
          .receive("error", (reply: { reason: string }) =>
            apply({ type: "notice", tone: "error", text: reply.reason }),
          );
      },

      setModel: (spec) =>
        push("set_model", { spec }, (reason) =>
          reason === "busy"
            ? "Can't switch model while the agent is working - interrupt it first."
            : reason,
        ),

      setReasoning: (effort) => {
        // Optimistic; the server echoes the normalized value via reasoning_changed.
        apply({ type: "reasoning_changed", effort });
        channel?.push("set_reasoning", { effort });
      },

      showNotice: (tone, text) => apply({ type: "notice", tone, text }),
    };
  });
}

// ── Selectors for values derived from `items` (kept out of stored state) ──

export const selectCompactionCount = (s: ConversationState) =>
  s.items.filter((item) => item.kind === "compaction").length;

/** The model in effect: the live override, or the conversation's own. */
export const selectCurrentModel = (s: ConversationState) => s.model ?? s.defaultModel;

export const selectNotices = (s: ConversationState) =>
  s.items.flatMap((item) =>
    item.kind === "notice" ? [{ tone: item.tone, text: item.text }] : [],
  );

/** Just the most recent notice (for the toast) — stable under useShallow. */
export const selectLastNotice = (s: ConversationState): { tone: "error" | "info"; text: string } | null => {
  for (let i = s.items.length - 1; i >= 0; i--) {
    const item = s.items[i];
    if (item.kind === "notice") return { tone: item.tone, text: item.text };
  }
  return null;
};

// ── React glue: one provider per conversation, slice-selecting hook ──

const StoreContext = createContext<ConversationStore | null>(null);
export const ConversationStoreProvider = StoreContext.Provider;

export function useConversationStore<T>(selector: (state: ConversationState) => T): T {
  const store = useContext(StoreContext);
  if (!store) {
    throw new Error("useConversationStore must be used within ConversationStoreProvider");
  }
  return useStore(store, selector);
}

export type { ContextUsage, ExtCommand, SubagentApproval, SubagentInfo } from "./channel";
