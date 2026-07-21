import { AssistantRuntimeProvider } from "@assistant-ui/react";
import {
  ChevronRight,
  Folder,
  FolderOpen,
  Layers,
  Loader2,
  Plus,
  Puzzle,
  Settings,
  Trash2,
} from "lucide-react";
import React, { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import {
  buildCSRFHeaders,
  createConversation,
  destroyConversation,
  listConversations,
} from "../ash_rpc";
import { TooltipProvider } from "../components/ui/tooltip";
import { Button } from "../components/ui/button";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuLabel,
  ContextMenuTrigger,
} from "../components/ui/context-menu";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../components/ui/dialog";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { ScrollArea } from "../components/ui/scroll-area";
import { cn } from "../lib/utils";
import { Thread } from "../components/assistant-ui/thread";
import { ConversationUsageContext } from "./ContextMeter";
import { ExtCommandsContext } from "./ExtCommandsContext";
import { ConversationModelContext } from "./ModelPicker";
import { useChannelRuntime } from "./runtime";
import { loadSettings, SETTING_KEYS } from "./settings";
import type { ConversationSummary } from "./types";

const DEFAULT_MODEL = "openai:gpt-5.4";

export function conversationLabel(conversation: ConversationSummary): string {
  if (conversation.title) return conversation.title;
  const parts = conversation.cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? conversation.cwd;
}

/** Last path segment of a workspace path — the folder label shown in the tree. */
export function folderName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

type ProjectGroup = { cwd: string; conversations: ConversationSummary[] };

/**
 * Group conversations by their workspace (cwd) into projects, most-recent
 * project first. Input is assumed sorted newest-first, so first-seen cwd wins
 * ordering and each group keeps that order.
 */
export function groupByProject(conversations: ConversationSummary[]): ProjectGroup[] {
  const groups = new Map<string, ConversationSummary[]>();
  for (const c of conversations) {
    const existing = groups.get(c.cwd);
    if (existing) existing.push(c);
    else groups.set(c.cwd, [c]);
  }
  return [...groups.entries()].map(([cwd, list]) => ({ cwd, conversations: list }));
}

export default function ChatApp() {
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const { conversationId } = useParams();
  const navigate = useNavigate();

  useEffect(() => {
    (async () => {
      const result = await listConversations({
        fields: ["id", "title", "cwd", "model"],
        sort: "-insertedAt",
        headers: buildCSRFHeaders(),
      });
      if (result.success) {
        setConversations(result.data);
        // Land on the most recent conversation when none is in the URL.
        if (!conversationId && result.data.length > 0) {
          navigate(`/c/${result.data[0].id}`, { replace: true });
        }
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const selected = conversations.find((c) => c.id === conversationId) ?? null;

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex h-screen bg-background text-foreground">
        <Sidebar
          conversations={conversations}
          selectedId={conversationId ?? null}
          onSelect={(id) => navigate(`/c/${id}`)}
          onCreated={(conversation) => {
            setConversations((prev) => [conversation, ...prev]);
            navigate(`/c/${conversation.id}`);
          }}
          onDelete={async (conversation) => {
            if (!confirm(`Delete "${conversationLabel(conversation)}"? This cannot be undone.`))
              return;
            const result = await destroyConversation({
              identity: conversation.id,
              headers: buildCSRFHeaders(),
            });
            // Only prune on a confirmed server delete — otherwise the row would
            // vanish from the UI but return on refresh.
            if (!result.success) {
              alert("Could not delete the conversation. Please try again.");
              return;
            }
            const remaining = conversations.filter((c) => c.id !== conversation.id);
            setConversations(remaining);
            if (conversationId && !remaining.some((c) => c.id === conversationId)) {
              navigate(remaining.length > 0 ? `/c/${remaining[0].id}` : "/", { replace: true });
            }
          }}
          onDeleteProject={async (project) => {
            const count = project.conversations.length;
            if (
              !confirm(
                `Delete project "${folderName(project.cwd)}" and its ${count} conversation${count === 1 ? "" : "s"}? This cannot be undone.`,
              )
            )
              return;
            // Prune only the conversations the server actually deleted.
            const outcomes = await Promise.all(
              project.conversations.map(async (c) => ({
                id: c.id,
                ok: (await destroyConversation({ identity: c.id, headers: buildCSRFHeaders() }))
                  .success,
              })),
            );
            const deleted = new Set(outcomes.filter((o) => o.ok).map((o) => o.id));
            const remaining = conversations.filter((c) => !deleted.has(c.id));
            setConversations(remaining);
            if (outcomes.some((o) => !o.ok)) {
              alert("Some conversations in this project couldn't be deleted. Please try again.");
            }
            if (conversationId && !remaining.some((c) => c.id === conversationId)) {
              navigate(remaining.length > 0 ? `/c/${remaining[0].id}` : "/", { replace: true });
            }
          }}
        />
        {selected ? (
          <ConversationPane
            key={selected.id}
            conversation={selected}
            onModelChanged={(id, model) =>
              setConversations((prev) =>
                prev.map((c) => (c.id === id ? { ...c, model } : c)),
              )
            }
            onTitled={(id, title) =>
              setConversations((prev) =>
                prev.map((c) => (c.id === id ? { ...c, title } : c)),
              )
            }
          />
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
  onDeleteProject: (project: ProjectGroup) => void;
}) {
  const navigate = useNavigate();
  const projects = useMemo(() => groupByProject(props.conversations), [props.conversations]);

  // A project folder is open when it's in this set. Default-collapsed, but the
  // active conversation's project stays open (effect below), so the tree opens
  // straight to what you're looking at.
  const [openFolders, setOpenFolders] = useState<Set<string>>(() => new Set());
  useEffect(() => {
    const selected = props.conversations.find((c) => c.id === props.selectedId);
    if (!selected) return;
    setOpenFolders((prev) => (prev.has(selected.cwd) ? prev : new Set(prev).add(selected.cwd)));
  }, [props.selectedId, props.conversations]);

  const toggleFolder = (cwd: string) =>
    setOpenFolders((prev) => {
      const next = new Set(prev);
      next.has(cwd) ? next.delete(cwd) : next.add(cwd);
      return next;
    });

  const [createFor, setCreateFor] = useState<{ cwd: string } | null>(null);

  return (
    <aside className="flex w-72 shrink-0 flex-col border-r border-border bg-card/30">
      <div className="flex h-14 shrink-0 items-center border-b border-border px-4">
        <span className="font-semibold tracking-wide">
          <span className="mr-2 text-primary">π</span>Longpi
        </span>
        <div className="flex-1" />
        <Button
          variant="ghost"
          size="icon"
          className="size-7"
          aria-label="Settings"
          onClick={() => navigate("/manage")}
        >
          <Settings className="size-4" />
        </Button>
      </div>

      <nav className="border-b border-border p-2">
        <button
          onClick={() => setCreateFor({ cwd: "" })}
          className="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-sm font-medium transition-colors hover:bg-accent"
        >
          <Plus className="size-4 text-muted-foreground" />
          New conversation
        </button>
        <button
          onClick={() => navigate("/manage/extensions")}
          className="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-sm font-medium transition-colors hover:bg-accent"
        >
          <Puzzle className="size-4 text-muted-foreground" />
          Extensions
        </button>
      </nav>

      <ScrollArea className="flex-1">
        <div className="flex items-center justify-between px-3 pt-3 pb-1">
          <span className="text-xs font-semibold tracking-wide text-muted-foreground uppercase">
            Projects
          </span>
        </div>

        {projects.length === 0 && (
          <p className="px-4 py-2 text-sm text-muted-foreground">No conversations yet.</p>
        )}

        <nav className="pb-2">
          {projects.map((project) => {
            const open = openFolders.has(project.cwd);
            const hasActive = project.conversations.some((c) => c.id === props.selectedId);
            return (
              <div key={project.cwd}>
                <ContextMenu>
                  <ContextMenuTrigger asChild>
                    <div
                      className={cn(
                        "group flex items-center transition-colors hover:bg-accent/60",
                        !open && hasActive && "bg-accent/40",
                      )}
                    >
                      <button
                        onClick={() => toggleFolder(project.cwd)}
                        className="flex min-w-0 flex-1 items-center gap-1.5 px-2.5 py-1.5 text-left"
                        title={project.cwd}
                      >
                        <ChevronRight
                          className={cn(
                            "size-3.5 shrink-0 text-muted-foreground transition-transform",
                            open && "rotate-90",
                          )}
                        />
                        {open ? (
                          <FolderOpen className="size-4 shrink-0 text-muted-foreground" />
                        ) : (
                          <Folder className="size-4 shrink-0 text-muted-foreground" />
                        )}
                        <span className="truncate text-sm font-medium">
                          {folderName(project.cwd)}
                        </span>
                        <span className="ml-auto shrink-0 pl-1 text-xs text-muted-foreground group-hover:hidden">
                          {project.conversations.length}
                        </span>
                      </button>
                      <button
                        onClick={() => setCreateFor({ cwd: project.cwd })}
                        aria-label="New conversation here"
                        className="mr-1.5 hidden rounded-md p-1 text-muted-foreground hover:bg-background hover:text-foreground group-hover:block"
                        title="New conversation in this project"
                      >
                        <Plus className="size-3.5" />
                      </button>
                    </div>
                  </ContextMenuTrigger>
                  <ContextMenuContent className="w-52">
                    <ContextMenuLabel className="truncate text-muted-foreground">
                      {folderName(project.cwd)}
                    </ContextMenuLabel>
                    <ContextMenuItem onSelect={() => setCreateFor({ cwd: project.cwd })}>
                      <Plus className="size-4" />
                      New conversation here
                    </ContextMenuItem>
                    <ContextMenuItem
                      variant="destructive"
                      onSelect={() => props.onDeleteProject(project)}
                    >
                      <Trash2 className="size-4" />
                      Delete project
                    </ContextMenuItem>
                  </ContextMenuContent>
                </ContextMenu>

                {open &&
                  project.conversations.map((conversation) => (
                    <div
                      key={conversation.id}
                      className={cn(
                        "group relative flex items-center transition-colors hover:bg-accent",
                        conversation.id === props.selectedId &&
                          "border-l-2 border-primary bg-accent",
                      )}
                    >
                      <button
                        onClick={() => props.onSelect(conversation.id)}
                        className="min-w-0 flex-1 py-1.5 pr-2 pl-8 text-left"
                      >
                        <div className="truncate text-sm">{conversationLabel(conversation)}</div>
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
              </div>
            );
          })}
        </nav>
      </ScrollArea>

      {createFor && (
        <NewConversationDialog
          initialCwd={createFor.cwd}
          onClose={() => setCreateFor(null)}
          onCreated={(conversation) => {
            setCreateFor(null);
            setOpenFolders((prev) => new Set(prev).add(conversation.cwd));
            props.onCreated(conversation);
          }}
        />
      )}
    </aside>
  );
}

/** Modal for starting a conversation: workspace path + model, prefilled from
 * the "+" the user clicked (a project's cwd, or blank for a new workspace). */
function NewConversationDialog({
  initialCwd,
  onClose,
  onCreated,
}: {
  initialCwd: string;
  onClose: () => void;
  onCreated: (conversation: ConversationSummary) => void;
}) {
  const [cwd, setCwd] = useState(initialCwd);
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
    if (result.success) onCreated(result.data);
    else setError("Could not create the conversation. Check the directory path.");
  }

  return (
    <Dialog open onOpenChange={(next) => !next && onClose()}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>New conversation</DialogTitle>
        </DialogHeader>
        <form onSubmit={create} className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="new-conv-cwd" className="text-xs text-muted-foreground">
              Workspace directory
            </Label>
            <Input
              id="new-conv-cwd"
              autoFocus
              className="font-mono text-xs"
              placeholder="/path/to/workspace"
              value={cwd}
              onChange={(e) => setCwd(e.target.value)}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="new-conv-model" className="text-xs text-muted-foreground">
              Model
            </Label>
            <Input
              id="new-conv-model"
              className="font-mono text-xs"
              placeholder="provider:model"
              value={model}
              onChange={(e) => setModel(e.target.value)}
            />
          </div>
          {error && <p className="text-xs text-destructive">{error}</p>}
          <div className="flex justify-end gap-2 pt-1">
            <Button type="button" variant="ghost" size="sm" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" size="sm" disabled={creating || !cwd.trim()}>
              {creating ? <Loader2 className="animate-spin" /> : <Plus />}
              Create
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function ConversationPane({
  conversation,
  onModelChanged,
  onTitled,
}: {
  conversation: ConversationSummary;
  onModelChanged: (id: string, model: string) => void;
  onTitled: (id: string, title: string) => void;
}) {
  const { runtime, compactionCount, notices, usage, currentModel, setModel, title, commands } =
    useChannelRuntime(conversation.id, conversation.model);

  const modelCtx = useMemo(
    () => ({ model: currentModel, setModel }),
    [currentModel, setModel],
  );

  const usageCtx = useMemo(
    () => (usage?.used != null && usage.window ? { used: usage.used, window: usage.window } : null),
    [usage?.used, usage?.window],
  );

  // Keep the sidebar label in sync when the model changes via /model.
  useEffect(() => {
    if (currentModel !== conversation.model) onModelChanged(conversation.id, currentModel);
  }, [currentModel]);

  // Adopt the auto-generated title into the sidebar once it arrives.
  useEffect(() => {
    if (title) onTitled(conversation.id, title);
  }, [title]);

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
        <header className="flex h-14 shrink-0 items-center gap-3 border-b border-border px-4">
          <div className="min-w-0">
            <h1 className="truncate text-sm font-semibold">{conversationLabel(conversation)}</h1>
            <p className="truncate font-mono text-xs text-muted-foreground">
              {conversation.cwd}
            </p>
          </div>
          <div className="flex-1" />
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
          <ConversationModelContext.Provider value={modelCtx}>
            <ConversationUsageContext.Provider value={usageCtx}>
              <ExtCommandsContext.Provider value={commands}>
                <Thread />
              </ExtCommandsContext.Provider>
            </ConversationUsageContext.Provider>
          </ConversationModelContext.Provider>
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
      </main>
    </AssistantRuntimeProvider>
  );
}
