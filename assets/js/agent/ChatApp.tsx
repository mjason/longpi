import React, { useEffect, useRef, useState } from "react";
import { buildCSRFHeaders, createConversation, listConversations } from "../ash_rpc";
import { useConversationChannel } from "./channel";
import type { ConversationSummary, ThreadItem } from "./types";

const DEFAULT_MODEL = "openai:gpt-5.4";

function conversationLabel(conversation: ConversationSummary): string {
  if (conversation.title) return conversation.title;
  const parts = conversation.cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? conversation.cwd;
}

export default function ChatApp() {
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  async function refresh(selectFirst = false) {
    const result = await listConversations({
      fields: ["id", "title", "cwd", "model"],
      sort: "-insertedAt",
      headers: buildCSRFHeaders(),
    });
    if (result.success) {
      setConversations(result.data);
      if (selectFirst && result.data.length > 0) setSelectedId(result.data[0].id);
    }
  }

  useEffect(() => {
    refresh(true);
  }, []);

  const selected = conversations.find((c) => c.id === selectedId) ?? null;

  return (
    <div className="flex h-screen bg-base-100 text-base-content">
      <Sidebar
        conversations={conversations}
        selectedId={selectedId}
        onSelect={setSelectedId}
        onCreated={(conversation) => {
          setConversations((prev) => [conversation, ...prev]);
          setSelectedId(conversation.id);
        }}
      />
      {selected ? (
        <ConversationPane key={selected.id} conversation={selected} />
      ) : (
        <main className="flex-1 grid place-items-center">
          <div className="text-center max-w-sm">
            <div className="text-5xl mb-4">π</div>
            <h1 className="text-xl font-semibold mb-2">Longpi</h1>
            <p className="opacity-60 text-sm">
              Pick a workspace on the left, or start a new conversation to put the agent to work.
            </p>
          </div>
        </main>
      )}
    </div>
  );
}

function Sidebar(props: {
  conversations: ConversationSummary[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  onCreated: (conversation: ConversationSummary) => void;
}) {
  const [cwd, setCwd] = useState("");
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function create(event: React.FormEvent) {
    event.preventDefault();
    if (!cwd.trim()) return;
    setCreating(true);
    setError(null);

    const result = await createConversation({
      input: { cwd: cwd.trim(), model: model.trim() || DEFAULT_MODEL },
      fields: ["id", "title", "cwd", "model"],
      headers: buildCSRFHeaders(),
    });

    setCreating(false);
    if (result.success) {
      setCwd("");
      props.onCreated(result.data);
    } else {
      setError("Could not create the conversation. Check the directory path.");
    }
  }

  return (
    <aside className="w-72 shrink-0 border-r border-base-300 flex flex-col">
      <div className="px-4 py-4 border-b border-base-300">
        <span className="font-semibold tracking-wide">
          <span className="text-primary mr-2">π</span>Longpi
        </span>
      </div>

      <form onSubmit={create} className="p-3 border-b border-base-300 space-y-2">
        <input
          className="input input-sm input-bordered w-full font-mono"
          placeholder="/path/to/workspace"
          value={cwd}
          onChange={(e) => setCwd(e.target.value)}
        />
        <input
          className="input input-sm input-bordered w-full font-mono"
          placeholder="provider:model"
          value={model}
          onChange={(e) => setModel(e.target.value)}
        />
        <button className="btn btn-primary btn-sm w-full" disabled={creating || !cwd.trim()}>
          {creating ? "Creating..." : "New conversation"}
        </button>
        {error && <p className="text-error text-xs">{error}</p>}
      </form>

      <nav className="flex-1 overflow-y-auto py-2">
        {props.conversations.length === 0 && (
          <p className="px-4 py-2 text-sm opacity-50">No conversations yet.</p>
        )}
        {props.conversations.map((conversation) => (
          <button
            key={conversation.id}
            onClick={() => props.onSelect(conversation.id)}
            className={`w-full text-left px-4 py-2.5 hover:bg-base-200 transition-colors ${
              conversation.id === props.selectedId ? "bg-base-200 border-l-2 border-primary" : ""
            }`}
          >
            <div className="text-sm font-medium truncate">{conversationLabel(conversation)}</div>
            <div className="text-xs opacity-50 font-mono truncate">{conversation.model}</div>
          </button>
        ))}
      </nav>
    </aside>
  );
}

function ConversationPane({ conversation }: { conversation: ConversationSummary }) {
  const { items, status, send, interrupt } = useConversationChannel(conversation.id);
  const [draft, setDraft] = useState("");
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: "end" });
  }, [items]);

  function submit() {
    const text = draft.trim();
    if (!text || status !== "idle") return;
    setDraft("");
    send(text);
  }

  return (
    <main className="flex-1 flex flex-col min-w-0">
      <header className="px-6 py-3 border-b border-base-300 flex items-center gap-3">
        <div className="min-w-0">
          <h1 className="text-sm font-semibold truncate">{conversationLabel(conversation)}</h1>
          <p className="text-xs opacity-50 font-mono truncate">
            {conversation.cwd} · {conversation.model}
          </p>
        </div>
        <div className="flex-1" />
        {status === "running" && (
          <span className="flex items-center gap-2 text-xs text-primary">
            <span className="pulse-dot" aria-hidden="true" />
            working
          </span>
        )}
        {status === "connecting" && <span className="text-xs opacity-50">connecting...</span>}
      </header>

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-3xl mx-auto px-6 py-6 space-y-4">
          {items.length === 0 && status === "idle" && (
            <p className="text-sm opacity-50 text-center py-12">
              The agent is ready in <span className="font-mono">{conversation.cwd}</span>. Ask it to
              do something.
            </p>
          )}
          {items.map((item, index) => (
            <ThreadItemView key={index} item={item} />
          ))}
          <div ref={bottomRef} />
        </div>
      </div>

      <footer className="border-t border-base-300 px-6 py-4">
        <div className="max-w-3xl mx-auto flex items-end gap-2">
          <textarea
            className="textarea textarea-bordered flex-1 min-h-12 max-h-48 leading-snug"
            placeholder={status === "running" ? "Agent is working..." : "Tell the agent what to do"}
            value={draft}
            rows={2}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                submit();
              }
            }}
          />
          {status === "running" ? (
            <button className="btn btn-outline btn-error" onClick={interrupt}>
              Stop
            </button>
          ) : (
            <button className="btn btn-primary" onClick={submit} disabled={!draft.trim()}>
              Send
            </button>
          )}
        </div>
      </footer>
    </main>
  );
}

function ThreadItemView({ item }: { item: ThreadItem }) {
  switch (item.kind) {
    case "user":
      return (
        <div className="flex justify-end">
          <div className="bg-base-300 rounded-2xl rounded-br-sm px-4 py-2.5 max-w-[85%] whitespace-pre-wrap text-sm">
            {item.text}
          </div>
        </div>
      );

    case "assistant":
      return (
        <div className={`agent-block ${item.streaming ? "agent-block-live" : ""}`}>
          <div className="whitespace-pre-wrap text-sm leading-relaxed">
            {item.text}
            {item.streaming && <span className="cursor-blink" aria-hidden="true" />}
          </div>
        </div>
      );

    case "tool":
      return <ToolCard item={item} />;

    case "notice":
      return (
        <p className={`text-xs text-center ${item.tone === "error" ? "text-error" : "opacity-50"}`}>
          {item.text}
        </p>
      );
  }
}

function ToolCard({ item }: { item: ThreadItem & { kind: "tool" } }) {
  const [open, setOpen] = useState(false);
  const summary = item.args ? summarizeArgs(item.name, item.args) : "";

  return (
    <div className={`agent-block ${item.running ? "agent-block-live" : ""}`}>
      <button
        onClick={() => setOpen(!open)}
        className="w-full text-left font-mono text-xs flex items-center gap-2 py-1"
      >
        <span className={item.error ? "text-error" : "text-accent"}>
          {item.running ? "▸" : item.error ? "✗" : "✓"}
        </span>
        <span className="font-semibold">{item.name}</span>
        <span className="opacity-60 truncate">{summary}</span>
      </button>
      {open && item.content && (
        <pre className="mt-1 p-3 bg-base-300/50 rounded text-xs font-mono overflow-x-auto max-h-80 overflow-y-auto whitespace-pre-wrap">
          {item.content}
        </pre>
      )}
    </div>
  );
}

function summarizeArgs(name: string, args: Record<string, unknown>): string {
  if (typeof args.command === "string") return args.command;
  if (typeof args.path === "string") return args.path;
  return Object.values(args)
    .filter((v) => typeof v === "string")
    .join(" ")
    .slice(0, 120);
}
