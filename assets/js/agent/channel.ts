import { Channel, Socket } from "phoenix";
import { useEffect, useRef } from "react";
import type { HistoryMessage, MessageAttachment, SessionStatus, ThreadItem } from "./types";
import { type ConversationStore, createConversationStore } from "./store";

let socket: Socket | null = null;

function getSocket(): Socket {
  if (!socket) {
    // With auth enabled the server embeds the session's bearer token; the
    // socket is rejected without it (see LongpiWeb.UserSocket). The embed view
    // has no signed-in session — its host passes ?token=<embedToken> instead,
    // which the socket accepts too.
    const token =
      document.querySelector('meta[name="socket-token"]')?.getAttribute("content") ||
      new URLSearchParams(location.search).get("token");
    socket = new Socket("/socket", token ? { params: { token } } : {});
    // @ts-expect-error phoenix's inferred JS types mark params as required,
    // but passing params to connect() is deprecated at runtime.
    socket.connect();
  }
  return socket;
}

type Dispatch = (action: ConversationAction) => void;

type ChannelEntry = {
  channel: Channel;
  dispatch: Dispatch;
  joined: Promise<void>;
  lastSeq: number;
};

// Drops events already seen on this channel. A reconnecting socket can leave a
// second channel process subscribed to the same topic, delivering every event
// twice; sequence numbers make that harmless.
function once(entry: ChannelEntry, seq: number | undefined, run: () => void) {
  if (typeof seq === "number") {
    if (seq <= entry.lastSeq) return;
    entry.lastSeq = seq;
  }
  run();
}

// One channel per topic for the whole app. Event handlers are registered once,
// at creation, and route to whichever hook currently owns `dispatch`. This is
// the key correctness guarantee: creating a channel per effect-run (or leaving
// a still-joining one) leaves multiple server channel processes subscribed to
// the same topic, so every push arrives twice and streamed text duplicates.
const entries = new Map<string, ChannelEntry>();

function acquireChannel(topic: string, dispatch: Dispatch): ChannelEntry {
  let entry = entries.get(topic);
  if (entry) {
    entry.dispatch = dispatch;
    return entry;
  }

  const channel = getSocket().channel(topic);
  entry = { channel, dispatch, joined: Promise.resolve(), lastSeq: 0 };
  entries.set(topic, entry);

  const e = entry;
  channel.on("history", (p: { messages: HistoryMessage[]; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "joined", messages: p.messages, status: "running" })),
  );
  channel.on("text_delta", (p: { text: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "text_delta", text: p.text })),
  );
  channel.on("thinking_delta", (p: { text: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "thinking_delta", text: p.text })),
  );
  channel.on("tool_call", (p: { id: string; name: string; args: Record<string, unknown>; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "tool_call", id: p.id, name: p.name, args: p.args })),
  );
  channel.on("tool_result", (p: { id: string; content: string; error: boolean; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "tool_result", id: p.id, content: p.content, error: p.error })),
  );
  channel.on("tool_output", (p: { id: string; chunk: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "tool_output", id: p.id, chunk: p.chunk })),
  );
  channel.on("approval_request", (p: { id: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "approval_request", id: p.id })),
  );
  channel.on("compacted", (p: { covered_through: number; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "compacted", coveredThrough: p.covered_through })),
  );
  channel.on("context_usage", (p: { used: number | null; window: number; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "context_usage", used: p.used, window: p.window })),
  );
  channel.on("model_changed", (p: { model: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "model_changed", model: p.model })),
  );
  channel.on("reasoning_changed", (p: { reasoning_effort: string | null; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "reasoning_changed", effort: p.reasoning_effort })),
  );
  channel.on("titled", (p: { title: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "titled", title: p.title })),
  );
  channel.on("commands", (p: { commands: ExtCommand[]; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "commands_updated", commands: p.commands })),
  );
  channel.on("subagents", (p: { agents: Record<string, SubagentInfo>; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "subagents_updated", agents: p.agents })),
  );
  channel.on("subagent_approval", (p: SubagentApproval & { seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "subagent_approval", approval: p })),
  );
  channel.on("subagent_approval_resolved", (p: { id: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "subagent_approval_resolved", id: p.id })),
  );
  channel.on("turn_ended", (p: { reason: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "turn_ended", reason: p.reason })),
  );
  channel.on("turn_failed", (p: { reason: string; seq?: number }) =>
    once(e, p.seq, () => e.dispatch({ type: "turn_failed", reason: p.reason })),
  );

  entry.joined = new Promise((resolve) => {
    channel
      .join()
      .receive("ok", (reply: JoinReply) => {
        e.dispatch({ type: "joined", messages: reply.messages, status: reply.status, pending: reply.pending_approvals, usage: reply.context_usage, reasoningEffort: reply.reasoning_effort, commands: reply.commands, subagents: reply.subagents, subagentApprovals: reply.subagent_approvals });
        resolve();
      })
      .receive("error", (reply: { reason: string }) => {
        e.dispatch({ type: "notice", tone: "error", text: `Could not join: ${reply.reason}` });
        resolve();
      });
  });

  return entry;
}

export type ContextUsage = { used: number | null; window: number };
export type ExtCommand = { name: string; description: string };

export type SubagentInfo = {
  conversationId: string;
  role: string;
  status: "running" | "done" | "failed" | "closed";
  task: string;
  startedAt: number;
};

export type SubagentApproval = {
  id: string;
  name: string;
  args: Record<string, unknown>;
  conversationId: string;
  role: string;
  handle: string;
};

type JoinReply = {
  messages: HistoryMessage[];
  status: string;
  pending_approvals?: string[];
  context_usage?: ContextUsage;
  reasoning_effort?: string | null;
  commands?: ExtCommand[];
  subagents?: Record<string, SubagentInfo>;
  subagent_approvals?: SubagentApproval[];
};

export type ConversationChannelState = {
  items: ThreadItem[];
  status: SessionStatus;
  usage: ContextUsage | null;
  // Model override from a live /model switch; null = use the conversation's own.
  model: string | null;
  // Reasoning effort for the model; null = the model's default (no override).
  reasoningEffort: string | null;
  // Auto-generated title from the first turn; null = use the conversation's own.
  title: string | null;
  // Slash commands contributed by extensions (for the composer's "/" menu).
  commands: ExtCommand[];
  // Subagents this conversation has spawned, keyed by handle ("scout-1").
  subagents: Record<string, SubagentInfo>;
  // Tool approvals bubbled up from subagents, keyed by call id.
  subagentApprovals: Record<string, SubagentApproval>;
};

export type ConversationAction =
  | { type: "joined"; messages: HistoryMessage[]; status: string; pending?: string[]; usage?: ContextUsage; commands?: ExtCommand[]; reasoningEffort?: string | null; subagents?: Record<string, SubagentInfo>; subagentApprovals?: SubagentApproval[] }
  | { type: "subagent_approval"; approval: SubagentApproval }
  | { type: "subagent_approval_resolved"; id: string }
  | { type: "model_changed"; model: string }
  | { type: "reasoning_changed"; effort: string | null }
  | { type: "titled"; title: string }
  | { type: "commands_updated"; commands: ExtCommand[] }
  | { type: "subagents_updated"; agents: Record<string, SubagentInfo> }
  | { type: "text_delta"; text: string }
  | { type: "thinking_delta"; text: string }
  | { type: "tool_call"; id: string; name: string; args: Record<string, unknown> }
  | { type: "tool_result"; id: string; content: string; error: boolean }
  | { type: "tool_output"; id: string; chunk: string }
  | { type: "approval_request"; id: string }
  | { type: "compacted"; coveredThrough: number }
  | { type: "context_usage"; used: number | null; window: number }
  | { type: "user_sent"; text: string; attachments?: MessageAttachment[] }
  | { type: "turn_ended"; reason: string }
  | { type: "turn_failed"; reason: string }
  | { type: "notice"; tone: "error" | "info"; text: string }
  | { type: "reset" };

// Cap live tool output so a chatty long-running command (a build, `find /`, a
// test run) can't grow the reducer state unboundedly. Keep the tail — the most
// recent output is what the user watches — with an elision marker.
const MAX_TOOL_OUTPUT = 32_768;
function capTail(text: string): string {
  return text.length > MAX_TOOL_OUTPUT ? "…\n" + text.slice(-MAX_TOOL_OUTPUT) : text;
}

// Items are a RENDER view of the DB rows: one row can yield 0..N items (an
// empty-text assistant row with tool calls yields only tool items; a tool
// RESULT row yields none — it fills the matching call item). Every item
// therefore carries `dbPos`, the DB position that "contains" it, which is
// what fork ("new conversation up to here") truncates at. Index-as-position
// was wrong and cut AI replies out of forks.
export function historyToItems(messages: HistoryMessage[], pending: string[] = []): ThreadItem[] {
  const items: ThreadItem[] = [];
  const pendingSet = new Set(pending);

  messages.forEach((message, dbPos) => {
    if (message.role === "user") {
      items.push({
        kind: "user",
        text: message.content,
        dbPos,
        ...(message.attachments?.length ? { attachments: message.attachments } : {}),
      });
    } else if (message.role === "assistant") {
      if (message.content.trim() !== "") {
        items.push({ kind: "assistant", text: message.content, streaming: false, dbPos, model: message.model ?? undefined });
      }
      for (const call of message.tool_calls ?? []) {
        const awaiting = pendingSet.has(call.id);
        items.push({
          kind: "tool",
          id: call.id,
          name: call.name,
          args: call.args,
          error: false,
          running: awaiting,
          awaitingApproval: awaiting,
          // Provisional: the call lives in the assistant row; the RESULT row
          // (the real fork boundary) overwrites this below when it arrives.
          dbPos,
        });
      }
    } else if (message.role === "tool" && message.tool_call_id) {
      const tool = items.find(
        (item) => item.kind === "tool" && item.id === message.tool_call_id,
      );
      if (tool && tool.kind === "tool") {
        tool.content = message.content;
        tool.error = message.error;
        tool.dbPos = dbPos;
      }
    }
  });

  return items;
}

function settle(items: ThreadItem[]): ThreadItem[] {
  return items.map((item) => {
    if (item.kind === "assistant" && item.streaming) return { ...item, streaming: false };
    if (item.kind === "reasoning" && item.streaming) return { ...item, streaming: false };
    if (item.kind === "tool" && item.running) return { ...item, running: false };
    return item;
  });
}

export function reduce(state: ConversationChannelState, action: ConversationAction): ConversationChannelState {
  switch (action.type) {
    case "reset":
      return { items: [], status: "connecting", usage: null, model: null, reasoningEffort: null, title: null, commands: [], subagents: {}, subagentApprovals: {} };

    case "model_changed":
      return { ...state, model: action.model };

    case "reasoning_changed":
      return { ...state, reasoningEffort: action.effort };

    case "titled":
      return { ...state, title: action.title };

    case "commands_updated":
      return { ...state, commands: action.commands };

    case "joined":
      return {
        ...state,
        items: historyToItems(action.messages, action.pending),
        status: action.status === "running" ? "running" : "idle",
        usage: action.usage ?? state.usage,
        reasoningEffort: action.reasoningEffort ?? state.reasoningEffort,
        commands: action.commands ?? state.commands,
        subagents: action.subagents ?? state.subagents,
        subagentApprovals: action.subagentApprovals
          ? Object.fromEntries(action.subagentApprovals.map((a) => [a.id, a]))
          : state.subagentApprovals,
      };

    case "subagents_updated":
      return { ...state, subagents: action.agents };

    case "subagent_approval":
      return {
        ...state,
        subagentApprovals: { ...state.subagentApprovals, [action.approval.id]: action.approval },
      };

    case "subagent_approval_resolved": {
      const { [action.id]: _removed, ...rest } = state.subagentApprovals;
      return { ...state, subagentApprovals: rest };
    }

    case "context_usage":
      return { ...state, usage: { used: action.used, window: action.window } };

    case "user_sent":
      return {
        ...state,
        status: "running",
        items: [
          ...state.items,
          {
            kind: "user",
            text: action.text,
            ...(action.attachments?.length ? { attachments: action.attachments } : {}),
          },
        ],
      };

    case "text_delta": {
      const items = [...state.items];
      const last = items[items.length - 1];
      if (last && last.kind === "assistant" && last.streaming) {
        items[items.length - 1] = { ...last, text: last.text + action.text };
      } else {
        items.push({ kind: "assistant", text: action.text, streaming: true });
      }
      return { ...state, status: "running", items };
    }

    case "thinking_delta": {
      const items = [...state.items];
      const last = items[items.length - 1];
      if (last && last.kind === "reasoning" && last.streaming) {
        items[items.length - 1] = { ...last, text: last.text + action.text };
      } else {
        items.push({ kind: "reasoning", text: action.text, streaming: true });
      }
      return { ...state, status: "running", items };
    }

    case "tool_call":
      return {
        ...state,
        status: "running",
        items: [
          ...settle(state.items),
          { kind: "tool", id: action.id, name: action.name, args: action.args, error: false, running: true },
        ],
      };

    case "approval_request":
      return {
        ...state,
        items: state.items.map((item) =>
          item.kind === "tool" && item.id === action.id
            ? { ...item, awaitingApproval: true }
            : item,
        ),
      };

    case "tool_output":
      return {
        ...state,
        items: state.items.map((item) =>
          item.kind === "tool" && item.id === action.id
            ? { ...item, output: capTail((item.output ?? "") + action.chunk) }
            : item,
        ),
      };

    case "tool_result":
      return {
        ...state,
        items: state.items.map((item) =>
          item.kind === "tool" && item.id === action.id
            ? { ...item, content: action.content, error: action.error, running: false, awaitingApproval: false }
            : item,
        ),
      };

    case "compacted":
      return {
        ...state,
        items: [...state.items, { kind: "compaction", coveredThrough: action.coveredThrough }],
      };

    case "turn_ended": {
      // On interrupt, any tool still running was killed with the turn — mark it
      // stopped so the user gets clear feedback (not a silent, stuck spinner).
      const interrupted = action.reason === "interrupted";
      const items = settle(state.items).map((item) =>
        // A tool with no result was killed with the turn — including one that was
        // mid-approval (clear awaitingApproval so its dead Allow/Deny gate closes).
        interrupted && item.kind === "tool" && item.content === undefined
          ? { ...item, content: "⏹ Stopped by user", error: true, awaitingApproval: false }
          : item,
      );
      if (interrupted) {
        items.push({ kind: "notice", tone: "info", text: "Turn interrupted" });
      }
      return { ...state, items, status: "idle" };
    }

    case "turn_failed":
      return {
        ...state,
        items: [...settle(state.items), { kind: "notice", tone: "error", text: `Turn failed: ${action.reason}` }],
        status: "idle",
      };

    case "notice":
      return { ...state, items: [...state.items, { kind: "notice", tone: action.tone, text: action.text }] };
  }
}

/**
 * Owns one conversation's zustand store and keeps it wired to the Phoenix
 * channel. Returns the store instance; components read slices via
 * `useConversationStore`. The channel event handlers drive the store through
 * its `apply` (the shared reducer); the store's actions push back through the
 * channel bound here.
 */
export function useConversationChannel(conversationId: string | null): ConversationStore {
  const storeRef = useRef<ConversationStore | null>(null);
  if (!storeRef.current) storeRef.current = createConversationStore();
  const store = storeRef.current;

  useEffect(() => {
    if (!conversationId) return;
    store.getState().apply({ type: "reset" });

    const dispatch: Dispatch = (action) => store.getState().apply(action);
    const entry = acquireChannel(`conversation:${conversationId}`, dispatch);
    store.getState().bindChannel(entry.channel);

    // If we re-acquired an already-joined channel (e.g. remount), the join
    // handler won't fire again - pull the current state explicitly.
    let cancelled = false;
    entry.joined.then(() => {
      if (cancelled || entry.channel.state !== "joined") return;
      entry.channel.push("get_state", {}).receive("ok", (reply: JoinReply) => {
        if (!cancelled)
          store.getState().apply({
            type: "joined",
            messages: reply.messages,
            status: reply.status,
            pending: reply.pending_approvals,
            usage: reply.context_usage,
            reasoningEffort: reply.reasoning_effort,
            commands: reply.commands,
            subagents: reply.subagents,
          });
      });
    });

    return () => {
      cancelled = true;
      store.getState().bindChannel(null);
    };
  }, [conversationId, store]);

  return store;
}
