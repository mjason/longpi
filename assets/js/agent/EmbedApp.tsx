import { Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { buildCSRFHeaders, createConversation, listConversations } from "../ash_rpc";
import { TooltipProvider } from "../components/ui/tooltip";
import { ConversationPane, DEFAULT_MODEL } from "./ChatApp";
import { loadSettings, SETTING_KEYS } from "./settings";
import type { ConversationSummary } from "./types";

/** Newest conversation for `cwd`, or null. Exported for tests. */
export function pickConversation(
  conversations: { cwd: string }[],
  cwd: string,
): number {
  return conversations.findIndex((c) => c.cwd === cwd);
}

/**
 * `/embed?cwd=/path[&model=spec][&theme=dark|light]` — a chrome-less agent
 * view for iframing inside a host app (e.g. dala's terminal pane).
 *
 * - `cwd` (required): the workspace to open. The newest conversation for that
 *   cwd is reused; when none exists one is created.
 * - `theme` is applied by the layout's pre-paint script (host-controlled).
 * - No sidebar/management chrome — just the conversation.
 */
export default function EmbedApp() {
  const [params] = useSearchParams();
  const cwd = (params.get("cwd") ?? "").trim();
  const modelParam = (params.get("model") ?? "").trim();

  const [conversation, setConversation] = useState<ConversationSummary | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!cwd) {
      setError("Missing ?cwd= — the host must say which workspace to open.");
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
        setError("Could not load conversations.");
        return;
      }

      const index = pickConversation(listed.data, cwd);
      if (index >= 0) {
        setConversation(listed.data[index]);
        return;
      }

      // No conversation for this workspace yet — create one.
      const model =
        modelParam ||
        (await loadSettings())[SETTING_KEYS.defaultModel] ||
        DEFAULT_MODEL;
      if (cancelled) return;

      const created = await createConversation({
        input: { cwd, model },
        fields: ["id", "title", "cwd", "model"],
        headers: buildCSRFHeaders(),
      });

      if (cancelled) return;
      if (created.success) setConversation(created.data);
      else setError("Could not create a conversation for this workspace.");
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cwd, modelParam]);

  if (error) {
    return (
      <div className="grid h-dvh place-items-center bg-background p-6 text-foreground">
        <p className="max-w-sm text-center text-sm text-muted-foreground">{error}</p>
      </div>
    );
  }

  if (!conversation) {
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
          key={conversation.id}
          conversation={conversation}
          onModelChanged={() => {}}
          onTitled={() => {}}
        />
      </div>
    </TooltipProvider>
  );
}
