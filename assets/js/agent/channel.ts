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

type State = { items: ThreadItem[]; status: SessionStatus };

type Action =
  | { type: "joined"; messages: HistoryMessage[]; status: string }
  | { type: "text_delta"; text: string }
  | { type: "tool_call"; id: string; name: string; args: Record<string, unknown> }
  | { type: "tool_result"; id: string; content: string; error: boolean }
  | { type: "user_sent"; text: string }
  | { type: "turn_ended"; reason: string }
  | { type: "turn_failed"; reason: string }
  | { type: "notice"; tone: "error" | "info"; text: string }
  | { type: "reset" };

function historyToItems(messages: HistoryMessage[]): ThreadItem[] {
  const items: ThreadItem[] = [];

  for (const message of messages) {
    if (message.role === "user") {
      items.push({ kind: "user", text: message.content });
    } else if (message.role === "assistant") {
      if (message.content.trim() !== "") {
        items.push({ kind: "assistant", text: message.content, streaming: false });
      }
      for (const call of message.tool_calls ?? []) {
        items.push({
          kind: "tool",
          id: call.id,
          name: call.name,
          args: call.args,
          error: false,
          running: false,
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
    if (item.kind === "tool" && item.running) return { ...item, running: false };
    return item;
  });
}

function reduce(state: State, action: Action): State {
  switch (action.type) {
    case "reset":
      return { items: [], status: "connecting" };

    case "joined":
      return {
        items: historyToItems(action.messages),
        status: action.status === "running" ? "running" : "idle",
      };

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

    case "tool_call":
      return {
        ...state,
        status: "running",
        items: [
          ...settle(state.items),
          { kind: "tool", id: action.id, name: action.name, args: action.args, error: false, running: true },
        ],
      };

    case "tool_result":
      return {
        ...state,
        items: state.items.map((item) =>
          item.kind === "tool" && item.id === action.id
            ? { ...item, content: action.content, error: action.error, running: false }
            : item,
        ),
      };

    case "turn_ended": {
      const items = settle(state.items);
      if (action.reason === "interrupted") {
        items.push({ kind: "notice", tone: "info", text: "Turn interrupted" });
      }
      return { items, status: "idle" };
    }

    case "turn_failed":
      return {
        items: [...settle(state.items), { kind: "notice", tone: "error", text: `Turn failed: ${action.reason}` }],
        status: "idle",
      };

    case "notice":
      return { ...state, items: [...state.items, { kind: "notice", tone: action.tone, text: action.text }] };
  }
}

export function useConversationChannel(conversationId: string | null) {
  const [state, dispatch] = useReducer(reduce, { items: [], status: "connecting" });
  const channelRef = useRef<Channel | null>(null);

  useEffect(() => {
    if (!conversationId) return;
    dispatch({ type: "reset" });

    const channel = getSocket().channel(`conversation:${conversationId}`);
    channelRef.current = channel;

    channel.on("text_delta", (p: { text: string }) => dispatch({ type: "text_delta", text: p.text }));
    channel.on("tool_call", (p: { id: string; name: string; args: Record<string, unknown> }) =>
      dispatch({ type: "tool_call", id: p.id, name: p.name, args: p.args }),
    );
    channel.on("tool_result", (p: { id: string; content: string; error: boolean }) =>
      dispatch({ type: "tool_result", id: p.id, content: p.content, error: p.error }),
    );
    channel.on("turn_ended", (p: { reason: string }) => dispatch({ type: "turn_ended", reason: p.reason }));
    channel.on("turn_failed", (p: { reason: string }) => dispatch({ type: "turn_failed", reason: p.reason }));

    channel
      .join()
      .receive("ok", (reply: { messages: HistoryMessage[]; status: string }) =>
        dispatch({ type: "joined", messages: reply.messages, status: reply.status }),
      )
      .receive("error", (reply: { reason: string }) =>
        dispatch({ type: "notice", tone: "error", text: `Could not join: ${reply.reason}` }),
      );

    return () => {
      channel.leave();
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

  return { ...state, send, interrupt };
}
