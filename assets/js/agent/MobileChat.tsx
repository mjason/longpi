import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { buildCSRFHeaders, getConversation } from "../ash_rpc";
import { TooltipProvider } from "../components/ui/tooltip";
import { ConversationPane } from "./ChatApp";
import type { ConversationSummary } from "./types";

/**
 * `/m/c/:conversationId[?token=...&theme=dark|light]` — a bare conversation
 * view for the native mobile shell: no sidebar, no web header (the native
 * navigation bar owns the title). The embed token in the URL authorizes the
 * WebView's session (same plug as /embed); theme lets the shell force
 * light/dark to match the app.
 */
export default function MobileChat() {
  const { conversationId } = useParams();
  const [conversation, setConversation] = useState<ConversationSummary | null>(null);
  const [missing, setMissing] = useState(false);

  // The shell may force a theme so the WebView matches the native chrome.
  useEffect(() => {
    const theme = new URLSearchParams(window.location.search).get("theme");
    if (theme === "dark" || theme === "light") {
      document.documentElement.setAttribute("data-theme", theme);
      document.documentElement.setAttribute("data-theme-source", "forced");
      document.documentElement.style.colorScheme = theme;
    }
  }, []);

  useEffect(() => {
    if (!conversationId) return;
    getConversation({
      getBy: { id: conversationId },
      fields: ["id", "title", "cwd", "model", "parentId", "agentRole"],
      headers: buildCSRFHeaders(),
    }).then((result) => {
      if (result.success && result.data) setConversation(result.data as ConversationSummary);
      else setMissing(true);
    });
  }, [conversationId]);

  if (missing) {
    return (
      <div className="grid h-dvh place-items-center text-sm text-muted-foreground">
        Conversation not found.
      </div>
    );
  }

  if (!conversation) return <div className="h-dvh bg-background" />;

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex h-dvh bg-background text-foreground">
        <ConversationPane
          conversation={conversation}
          bare
          onModelChanged={() => {}}
          onTitled={() => {}}
        />
      </div>
    </TooltipProvider>
  );
}
