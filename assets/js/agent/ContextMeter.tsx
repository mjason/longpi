import { ContextDisplay } from "../components/assistant-ui/context-display";
import { useConversationStore } from "./store";

/**
 * Compact context-window meter docked in the composer action row, built on
 * assistant-ui's ContextDisplay (Ring preset: a small progress ring + percent,
 * with a token breakdown on hover). Usage is fed in from our channel since the
 * agent loop runs server-side. Renders nothing until usage is known.
 */
export function ComposerContextMeter() {
  const usage = useConversationStore((s) => s.usage);
  if (!usage || usage.used == null || usage.window <= 0) return null;

  return (
    <ContextDisplay.Ring
      modelContextWindow={usage.window}
      usage={{ inputTokens: usage.used, totalTokens: usage.used }}
      side="top"
      showLabel={false}
    />
  );
}
