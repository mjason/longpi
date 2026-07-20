import { AssistantRuntimeProvider } from "@assistant-ui/react";
import { Layers, Loader2, Plus, Settings, ShieldAlert, Trash2 } from "lucide-react";
import React, { useEffect, useState } from "react";
import {
  buildCSRFHeaders,
  createConversation,
  destroyConversation,
  listConversations,
} from "../ash_rpc";
import { TooltipProvider } from "../components/ui/tooltip";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { ScrollArea } from "../components/ui/scroll-area";
import { cn } from "../lib/utils";
import { Thread } from "../components/assistant-ui/thread";
import type { ContextUsage } from "./channel";
import { useChannelRuntime } from "./runtime";
import { SettingsDialog } from "./SettingsDialog";
import { loadSettings, SETTING_KEYS } from "./settings";
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
          onDelete={async (conversation) => {
            if (!confirm(`Delete "${conversationLabel(conversation)}"? This cannot be undone.`))
              return;
            await destroyConversation({ identity: conversation.id, headers: buildCSRFHeaders() });
            setConversations((prev) => prev.filter((c) => c.id !== conversation.id));
            setSelectedId((cur) => (cur === conversation.id ? null : cur));
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
  onDelete: (conversation: ConversationSummary) => void;
}) {
  const [cwd, setCwd] = useState("");
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);

  // Prefill the model from the saved default_model setting.
  useEffect(() => {
    loadSettings().then((s) => {
      const preset = s[SETTING_KEYS.defaultModel];
      if (preset) setModel(preset);
    });
  }, []);

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
      <div className="flex items-center border-b border-border px-4 py-4">
        <span className="font-semibold tracking-wide">
          <span className="mr-2 text-primary">π</span>Longpi
        </span>
        <div className="flex-1" />
        <Button
          variant="ghost"
          size="icon"
          className="size-7"
          aria-label="Settings"
          onClick={() => setSettingsOpen(true)}
        >
          <Settings className="size-4" />
        </Button>
      </div>

      <SettingsDialog open={settingsOpen} onOpenChange={setSettingsOpen} />

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
            <div
              key={conversation.id}
              className={cn(
                "group relative flex items-center transition-colors hover:bg-accent",
                conversation.id === props.selectedId && "border-l-2 border-primary bg-accent",
              )}
            >
              <button
                onClick={() => props.onSelect(conversation.id)}
                className="min-w-0 flex-1 px-4 py-2.5 text-left"
              >
                <div className="truncate text-sm font-medium">
                  {conversationLabel(conversation)}
                </div>
                <div className="truncate font-mono text-xs text-muted-foreground">
                  {conversation.model}
                </div>
              </button>
              <button
                onClick={() => props.onDelete(conversation)}
                aria-label="Delete conversation"
                className="mr-2 hidden rounded-md p-1.5 text-muted-foreground hover:bg-background hover:text-destructive group-hover:block"
              >
                <Trash2 className="size-4" />
              </button>
            </div>
          ))}
        </nav>
      </ScrollArea>
    </aside>
  );
}

function ConversationPane({ conversation }: { conversation: ConversationSummary }) {
  const { runtime, pendingApprovals, respondApproval, compactionCount, notices, usage } =
    useChannelRuntime(conversation.id);

  // Show the most recent notice briefly (command echoes, errors, interrupts).
  const [toast, setToast] = useState<{ tone: "error" | "info"; text: string } | null>(null);
  const lastNotice = notices[notices.length - 1];
  useEffect(() => {
    if (!lastNotice) return;
    setToast(lastNotice);
    const t = setTimeout(() => setToast(null), 3500);
    return () => clearTimeout(t);
  }, [notices.length]);

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
          <div className="flex-1" />
          <ContextMeter usage={usage} />
          {compactionCount > 0 && (
            <span
              className="flex items-center gap-1.5 rounded-full bg-secondary px-2.5 py-1 text-xs text-muted-foreground"
              title="Older messages have been summarized to fit the model's context window. The full history is still stored."
            >
              <Layers className="size-3.5" />
              context compacted{compactionCount > 1 ? ` ×${compactionCount}` : ""}
            </span>
          )}
        </header>

        <div className="min-h-0 flex-1">
          <Thread />
        </div>

        {toast && (
          <div
            className={cn(
              "border-t px-4 py-2 text-center text-xs",
              toast.tone === "error"
                ? "border-destructive/30 bg-destructive/5 text-destructive"
                : "border-border bg-secondary/40 text-muted-foreground",
            )}
          >
            {toast.text}
          </div>
        )}

        {pendingApprovals.map((req) => (
          <ApprovalBanner key={req.id} request={req} onRespond={respondApproval} />
        ))}
      </main>
    </AssistantRuntimeProvider>
  );
}

function formatTokens(n: number): string {
  return n >= 1000 ? `${Math.round(n / 1000)}k` : String(n);
}

// How full the model's context window is, as of the last turn. Turns amber as
// it nears the compaction threshold (compaction auto-summarizes around 80%).
function ContextMeter({ usage }: { usage: ContextUsage | null }) {
  if (!usage || usage.used == null || !usage.window) return null;
  const pct = Math.min(100, Math.round((usage.used / usage.window) * 100));
  const warn = pct >= 80;

  return (
    <div
      className="flex items-center gap-2"
      title={`Context window: ${usage.used.toLocaleString()} / ${usage.window.toLocaleString()} tokens (${pct}%)`}
    >
      <div className="h-1.5 w-16 overflow-hidden rounded-full bg-secondary">
        <div
          className={cn("h-full rounded-full transition-[width]", warn ? "bg-amber-500" : "bg-primary")}
          style={{ width: `${pct}%` }}
        />
      </div>
      <span className={cn("font-mono text-xs tabular-nums", warn ? "text-amber-600" : "text-muted-foreground")}>
        {formatTokens(usage.used)}/{formatTokens(usage.window)}
      </span>
    </div>
  );
}

function ApprovalBanner({
  request,
  onRespond,
}: {
  request: { id: string; name: string; args?: Record<string, unknown> };
  onRespond: (id: string, approved: boolean) => void;
}) {
  const summary =
    typeof request.args?.command === "string"
      ? request.args.command
      : typeof request.args?.path === "string"
        ? request.args.path
        : "";

  return (
    <div className="border-t border-primary/30 bg-primary/5 px-4 py-3">
      <div className="mx-auto flex w-full max-w-[44rem] items-center gap-3">
        <ShieldAlert className="size-5 shrink-0 text-primary" />
        <div className="min-w-0 flex-1 text-sm">
          <span className="font-medium">The agent wants to run </span>
          <code className="font-mono font-semibold">{request.name}</code>
          {summary && (
            <code className="ml-1 block truncate font-mono text-xs text-muted-foreground">{summary}</code>
          )}
        </div>
        <Button size="sm" variant="outline" onClick={() => onRespond(request.id, false)}>
          Deny
        </Button>
        <Button size="sm" onClick={() => onRespond(request.id, true)}>
          Allow
        </Button>
      </div>
    </div>
  );
}
