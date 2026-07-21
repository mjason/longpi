import { createContext, useContext } from "react";
import { ContextDisplay } from "../components/assistant-ui/context-display";

/** Live context-window usage for the current conversation, surfaced to the
 * composer's inline meter. Null until the first turn reports usage. */
export type ConversationUsage = { used: number; window: number };
export const ConversationUsageContext = createContext<ConversationUsage | null>(null);

/**
 * Compact context-window meter docked in the composer action row, built on
 * assistant-ui's ContextDisplay (Ring preset: a small progress ring + percent,
 * with a token breakdown on hover). Usage is fed in from our channel since the
 * agent loop runs server-side. Renders nothing until usage is known.
 */
export function ComposerContextMeter() {
  const usage = useContext(ConversationUsageContext);
  if (!usage || usage.window <= 0) return null;

  return (
    <ContextDisplay.Ring
      modelContextWindow={usage.window}
      usage={{ inputTokens: usage.used, totalTokens: usage.used }}
      side="top"
      showLabel={false}
    />
  );
}
