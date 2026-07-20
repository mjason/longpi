export type HistoryMessage = {
  role: "user" | "assistant" | "tool";
  content: string;
  tool_calls: { id: string; name: string; args: Record<string, unknown> }[];
  tool_call_id: string | null;
  name: string | null;
  error: boolean;
};

export type ThreadItem =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string; streaming: boolean }
  | {
      kind: "tool";
      id: string;
      name: string;
      args?: Record<string, unknown>;
      content?: string;
      error: boolean;
      running: boolean;
    }
  | { kind: "notice"; tone: "error" | "info"; text: string };

export type SessionStatus = "connecting" | "idle" | "running";

export type ConversationSummary = {
  id: string;
  title: string | null;
  cwd: string;
  model: string;
};
