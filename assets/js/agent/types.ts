/**
 * A message attachment on the wire (browser ⇄ Elixir, same JSON both ways).
 * Images carry base64 bytes (no `data:` prefix) for the vision model; text
 * files are inlined as `<attachment>`-wrapped text.
 */
export type MessageAttachment =
  | { type: "image"; name: string; media_type: string; data: string }
  | { type: "file"; name: string; text: string };

export type HistoryMessage = {
  role: "user" | "assistant" | "tool";
  content: string;
  attachments?: MessageAttachment[] | null;
  tool_calls: { id: string; name: string; args: Record<string, unknown> }[];
  tool_call_id: string | null;
  name: string | null;
  error: boolean;
};

export type ThreadItem =
  | { kind: "user"; text: string; attachments?: MessageAttachment[]; dbPos?: number }
  | { kind: "assistant"; text: string; streaming: boolean; dbPos?: number }
  | { kind: "reasoning"; text: string; streaming: boolean }
  | {
      kind: "tool";
      /** DB position of this tool's RESULT row (fork boundary). */
      dbPos?: number;
      id: string;
      name: string;
      args?: Record<string, unknown>;
      content?: string;
      // Live output streamed while the tool runs (e.g. bash stdout/stderr),
      // shown until the final `content` arrives.
      output?: string;
      error: boolean;
      running: boolean;
      // Set while the tool is waiting for the user to approve/reject it.
      awaitingApproval?: boolean;
    }
  | { kind: "notice"; tone: "error" | "info"; text: string }
  | { kind: "compaction"; coveredThrough: number };

export type SessionStatus = "connecting" | "idle" | "running";

export type ConversationSummary = {
  id: string;
  title: string | null;
  cwd: string;
  model: string;
  /** Set on subagent conversations: the spawning conversation's id. */
  parentId?: string | null;
  /** Set on subagent conversations: the role it was spawned as ("scout"). */
  agentRole?: string | null;
};
