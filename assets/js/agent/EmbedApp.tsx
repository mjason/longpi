import type { ExternalStoreThreadListAdapter } from "@assistant-ui/react";
import { History, Loader2 } from "lucide-react";
import { useMemo, useState } from "react";
import { useEffect } from "react";
import { useSearchParams } from "react-router-dom";
import { buildCSRFHeaders, createConversation, listConversations } from "../ash_rpc";
import { ThreadList } from "../components/assistant-ui/thread-list";
import { Button } from "../components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "../components/ui/popover";
import { TooltipProvider } from "../components/ui/tooltip";
import { ConversationPane, DEFAULT_MODEL, conversationLabel } from "./ChatApp";
import { useI18n } from "./i18n";
import { loadSettings, SETTING_KEYS } from "./settings";
import type { ConversationSummary } from "./types";

/** Newest conversation for `cwd`, or -1. Exported for tests. */
export function pickConversation(conversations: { cwd: string }[], cwd: string): number {
  return conversations.findIndex((c) => c.cwd === cwd);
}

/**
 * `/embed?cwd=/path[&model=spec][&theme=dark|light][&token=...]` — a
 * chrome-less agent view for iframing inside a host app (e.g. dala's terminal
 * pane).
 *
 * - `cwd` (required): the workspace to open. The newest conversation for that
 *   cwd is opened; when none exists one is created.
 * - The header's history button manages THIS workspace's conversations
 *   (assistant-ui ThreadList: switch or start a new one).
 * - `theme` is applied by the layout's pre-paint script (host-controlled).
 * - `token` authenticates the iframe when auth is enabled (see Longpi.Auth).
 */
export default function EmbedApp() {
  const { t } = useI18n();
  const [params] = useSearchParams();
  const cwd = (params.get("cwd") ?? "").trim();
  const modelParam = (params.get("model") ?? "").trim();

  // All conversations for this workspace, newest first; `activeId` selects.
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  async function defaultModel(): Promise<string> {
    return modelParam || (await loadSettings())[SETTING_KEYS.defaultModel] || DEFAULT_MODEL;
  }

  async function createForCwd(): Promise<ConversationSummary | null> {
    const created = await createConversation({
      input: { cwd, model: await defaultModel() },
      fields: ["id", "title", "cwd", "model"],
      headers: buildCSRFHeaders(),
    });
    return created.success ? created.data : null;
  }

  useEffect(() => {
    if (!cwd) {
      setError(t("embed.missingCwd"));
      setLoading(false);
      return;
    }

    let cancelled = false;

    (async () => {
      const listed = await listConversations({
        fields: ["id", "title", "cwd", "model"],
        sort: "-insertedAt",
        headers: buildCSRFHeaders(),
      });

      if (cancelled) return;
      if (!listed.success) {
        setError(t("embed.loadFailed"));
        setLoading(false);
        return;
      }

      const mine = listed.data.filter((c) => c.cwd === cwd);
      if (mine.length > 0) {
        setConversations(mine);
        setActiveId(mine[0].id);
      } else {
        const created = await createForCwd();
        if (cancelled) return;
        if (!created) {
          setError(t("embed.createFailed"));
          setLoading(false);
          return;
        }
        setConversations([created]);
        setActiveId(created.id);
      }

      setLoading(false);
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cwd, modelParam]);

  const active = conversations.find((c) => c.id === activeId) ?? null;

  // assistant-ui's ThreadList reads this via the runtime (ExternalStore
  // threadList adapter): this workspace's conversations, switch, and new.
  const threadList = useMemo<ExternalStoreThreadListAdapter>(
    () => ({
      threadId: activeId ?? undefined,
      threads: conversations.map((c) => ({
        id: c.id,
        status: "regular" as const,
        title: conversationLabel(c),
      })),
      onSwitchToThread: (id) => setActiveId(id),
      onSwitchToNewThread: async () => {
        const created = await createForCwd();
        if (created) {
          setConversations((prev) => [created, ...prev]);
          setActiveId(created.id);
        }
      },
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [activeId, conversations, cwd, modelParam],
  );

  if (error) {
    return (
      <div className="grid h-dvh place-items-center bg-background p-6 text-foreground">
        <p className="max-w-sm text-center text-sm text-muted-foreground">{error}</p>
      </div>
    );
  }

  if (loading || !active) {
    return (
      <div className="grid h-dvh place-items-center bg-background text-foreground">
        <Loader2 className="size-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex h-dvh bg-background text-foreground">
        <ConversationPane
          key={active.id}
          conversation={active}
          threadList={threadList}
          headerExtra={<EmbedThreadSwitcher count={conversations.length} />}
          onModelChanged={(id, model) =>
            setConversations((prev) => prev.map((c) => (c.id === id ? { ...c, model } : c)))
          }
          onTitled={(id, title) =>
            setConversations((prev) => prev.map((c) => (c.id === id ? { ...c, title } : c)))
          }
          onForked={(fork) => {
            setConversations((prev) => [fork as ConversationSummary, ...prev]);
            setActiveId(fork.id);
          }}
        />
      </div>
    </TooltipProvider>
  );
}

/**
 * Header popover managing this workspace's conversations — assistant-ui's
 * ThreadList (new / switch) scoped to the embed's cwd.
 */
function EmbedThreadSwitcher({ count }: { count: number }) {
  const { t } = useI18n();
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="sm"
          className="h-7 gap-1.5 px-2 text-xs text-muted-foreground hover:text-foreground"
          aria-label={t("embed.threads")}
        >
          <History className="size-4" />
          {count > 1 ? count : null}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-72 p-2">
        <ThreadList />
      </PopoverContent>
    </Popover>
  );
}
