import { Channel, Socket } from "phoenix";
import { useEffect, useReducer, useRef } from "react";
import type { HistoryMessage, SessionStatus, ThreadItem } from "./types";

let socket: Socket | null = null;

function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", {});
    // @ts-expect-error phoenix's inferred JS types mark params as required,
    // but passing params to connect() is deprecated at runtime.
    socket.connect();
  }
  return socket;
}

type Dispatch = (action: Action) => void;

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
        e.dispatch({ type: "joined", messages: reply.messages, status: reply.status, pending: reply.pending_approvals, usage: reply.context_usage });
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

type JoinReply = {
  messages: HistoryMessage[];
  status: string;
  pending_approvals?: string[];
  context_usage?: ContextUsage;
};

type State = {
  items: ThreadItem[];
  status: SessionStatus;
  usage: ContextUsage | null;
  // Model override from a live /model switch; null = use the conversation's own.
  model: string | null;
};

type Action =
  | { type: "joined"; messages: HistoryMessage[]; status: string; pending?: string[]; usage?: ContextUsage }
  | { type: "model_changed"; model: string }
  | { type: "text_delta"; text: string }
  | { type: "thinking_delta"; text: string }
  | { type: "tool_call"; id: string; name: string; args: Record<string, unknown> }
  | { type: "tool_result"; id: string; content: string; error: boolean }
  | { type: "approval_request"; id: string }
  | { type: "compacted"; coveredThrough: number }
  | { type: "context_usage"; used: number | null; window: number }
  | { type: "user_sent"; text: string }
  | { type: "turn_ended"; reason: string }
  | { type: "turn_failed"; reason: string }
  | { type: "notice"; tone: "error" | "info"; text: string }
  | { type: "reset" };

function historyToItems(messages: HistoryMessage[], pending: string[] = []): ThreadItem[] {
  const items: ThreadItem[] = [];
  const pendingSet = new Set(pending);

  for (const message of messages) {
    if (message.role === "user") {
      items.push({ kind: "user", text: message.content });
    } else if (message.role === "assistant") {
      if (message.content.trim() !== "") {
        items.push({ kind: "assistant", text: message.content, streaming: false });
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
        });
      }
    } else if (message.role === "tool" && message.tool_call_id) {
      const tool = items.find(
        (item) => item.kind === "tool" && item.id === message.tool_call_id,
      );
      if (tool && tool.kind === "tool") {
        tool.content = message.content;
        tool.error = message.error;
      }
    }
  }

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

function reduce(state: State, action: Action): State {
  switch (action.type) {
    case "reset":
      return { items: [], status: "connecting", usage: null, model: null };

    case "model_changed":
      return { ...state, model: action.model };

    case "joined":
      return {
        ...state,
        items: historyToItems(action.messages, action.pending),
        status: action.status === "running" ? "running" : "idle",
        usage: action.usage ?? state.usage,
      };

    case "context_usage":
      return { ...state, usage: { used: action.used, window: action.window } };

    case "user_sent":
      return { ...state, status: "running", items: [...state.items, { kind: "user", text: action.text }] };

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
      const items = settle(state.items);
      if (action.reason === "interrupted") {
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

export function useConversationChannel(conversationId: string | null) {
  const [state, dispatch] = useReducer(reduce, {
    items: [],
    status: "connecting",
    usage: null,
    model: null,
  });
  const channelRef = useRef<Channel | null>(null);

  useEffect(() => {
    if (!conversationId) return;
    dispatch({ type: "reset" });

    const entry = acquireChannel(`conversation:${conversationId}`, dispatch);
    channelRef.current = entry.channel;

    // If we re-acquired an already-joined channel (e.g. remount), the join
    // handler won't fire again - pull the current history explicitly.
    let cancelled = false;
    entry.joined.then(() => {
      if (cancelled || entry.channel.state !== "joined") return;
      entry.channel
        .push("get_state", {})
        .receive("ok", (reply: JoinReply) => {
          if (!cancelled)
            dispatch({ type: "joined", messages: reply.messages, status: reply.status, pending: reply.pending_approvals, usage: reply.context_usage });
        });
    });

    return () => {
      cancelled = true;
      channelRef.current = null;
    };
  }, [conversationId]);

  function send(text: string) {
    dispatch({ type: "user_sent", text });
    channelRef.current
      ?.push("send_message", { text })
      .receive("error", (reply: { reason: string }) =>
        dispatch({
          type: "notice",
          tone: "error",
          text: reply.reason === "busy" ? "The agent is still working - interrupt it first." : reply.reason,
        }),
      );
  }

  function interrupt() {
    channelRef.current?.push("interrupt", {});
  }

  function regenerate() {
    channelRef.current
      ?.push("regenerate", {})
      .receive("error", (reply: { reason: string }) =>
        dispatch({ type: "notice", tone: "error", text: reply.reason }),
      );
  }

  function respondApproval(id: string, approved: boolean) {
    channelRef.current?.push("permission_response", { id, approved });
  }

  function showNotice(tone: "error" | "info", text: string) {
    dispatch({ type: "notice", tone, text });
  }

  function setModel(spec: string) {
    channelRef.current
      ?.push("set_model", { spec })
      .receive("error", (reply: { reason: string }) =>
        dispatch({
          type: "notice",
          tone: "error",
          text:
            reply.reason === "busy"
              ? "Can't switch model while the agent is working - interrupt it first."
              : reply.reason,
        }),
      );
  }

  function runCommand(name: string) {
    dispatch({ type: "notice", tone: "info", text: `/${name}` });
    channelRef.current
      ?.push("command", { name })
      .receive("error", (reply: { reason: string }) =>
        dispatch({ type: "notice", tone: "error", text: reply.reason }),
      );
  }

  const pendingApprovals = state.items.flatMap((item) =>
    item.kind === "tool" && item.awaitingApproval
      ? [{ id: item.id, name: item.name, args: item.args }]
      : [],
  );

  const compactionCount = state.items.filter((item) => item.kind === "compaction").length;
  const notices = state.items.flatMap((item) =>
    item.kind === "notice" ? [{ tone: item.tone, text: item.text }] : [],
  );

  return {
    ...state,
    send,
    interrupt,
    regenerate,
    respondApproval,
    runCommand,
    setModel,
    showNotice,
    pendingApprovals,
    compactionCount,
    notices,
  };
}
