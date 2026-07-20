import { AssistantRuntimeProvider } from "@assistant-ui/react";
import { Loader2, Plus } from "lucide-react";
import React, { useEffect, useState } from "react";
import { buildCSRFHeaders, createConversation, listConversations } from "../ash_rpc";
import { TooltipProvider } from "../components/ui/tooltip";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { ScrollArea } from "../components/ui/scroll-area";
import { cn } from "../lib/utils";
import { Thread } from "../components/assistant-ui/thread";
import { useChannelRuntime } from "./runtime";
import type { ConversationSummary } from "./types";

const DEFAULT_MODEL = "openai:gpt-5.4";

function conversationLabel(conversation: ConversationSummary): string {
  if (conversation.title) return conversation.title;
  const parts = conversation.cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? conversation.cwd;
}

export default function ChatApp() {
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const result = await listConversations({
        fields: ["id", "title", "cwd", "model"],
        sort: "-insertedAt",
        headers: buildCSRFHeaders(),
      });
      if (result.success) {
        setConversations(result.data);
        if (result.data.length > 0) setSelectedId(result.data[0].id);
      }
    })();
  }, []);

  const selected = conversations.find((c) => c.id === selectedId) ?? null;

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex h-screen bg-background text-foreground">
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
          <main className="grid flex-1 place-items-center">
            <div className="max-w-sm text-center">
              <div className="mb-4 text-5xl text-primary">π</div>
              <h1 className="mb-2 text-xl font-semibold">Longpi</h1>
              <p className="text-sm text-muted-foreground">
                Pick a workspace on the left, or start a new conversation to put the agent to work.
              </p>
            </div>
          </main>
        )}
      </div>
    </TooltipProvider>
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
    <aside className="flex w-72 shrink-0 flex-col border-r border-border bg-card/30">
      <div className="border-b border-border px-4 py-4">
        <span className="font-semibold tracking-wide">
          <span className="mr-2 text-primary">π</span>Longpi
        </span>
      </div>

      <form onSubmit={create} className="space-y-2 border-b border-border p-3">
        <Input
          className="font-mono text-xs"
          placeholder="/path/to/workspace"
          value={cwd}
          onChange={(e) => setCwd(e.target.value)}
        />
        <Input
          className="font-mono text-xs"
          placeholder="provider:model"
          value={model}
          onChange={(e) => setModel(e.target.value)}
        />
        <Button type="submit" size="sm" className="w-full" disabled={creating || !cwd.trim()}>
          {creating ? <Loader2 className="animate-spin" /> : <Plus />}
          New conversation
        </Button>
        {error && <p className="text-xs text-destructive">{error}</p>}
      </form>

      <ScrollArea className="flex-1">
        <nav className="py-2">
          {props.conversations.length === 0 && (
            <p className="px-4 py-2 text-sm text-muted-foreground">No conversations yet.</p>
          )}
          {props.conversations.map((conversation) => (
            <button
              key={conversation.id}
              onClick={() => props.onSelect(conversation.id)}
              className={cn(
                "w-full px-4 py-2.5 text-left transition-colors hover:bg-accent",
                conversation.id === props.selectedId &&
                  "border-l-2 border-primary bg-accent",
              )}
            >
              <div className="truncate text-sm font-medium">{conversationLabel(conversation)}</div>
              <div className="truncate font-mono text-xs text-muted-foreground">
                {conversation.model}
              </div>
            </button>
          ))}
        </nav>
      </ScrollArea>
    </aside>
  );
}

function ConversationPane({ conversation }: { conversation: ConversationSummary }) {
  const runtime = useChannelRuntime(conversation.id);

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-3 border-b border-border px-4 py-2.5">
          <div className="min-w-0">
            <h1 className="truncate text-sm font-semibold">{conversationLabel(conversation)}</h1>
            <p className="truncate font-mono text-xs text-muted-foreground">
              {conversation.cwd} · {conversation.model}
            </p>
          </div>
        </header>

        <div className="min-h-0 flex-1">
          <Thread />
        </div>
      </main>
    </AssistantRuntimeProvider>
  );
}
