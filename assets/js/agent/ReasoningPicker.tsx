import { Brain, Check, ChevronDown } from "lucide-react";
import { createContext, useContext } from "react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "../components/ui/dropdown-menu";
import { cn } from "../lib/utils";

/** Current conversation's reasoning effort + setter, surfaced to the composer.
 * `effort` is null when the model's default is used. Null context = no
 * conversation (e.g. the management view). */
export const ReasoningEffortContext = createContext<{
  effort: string | null;
  setEffort: (effort: string | null) => void;
} | null>(null);

// null = "Auto" (send no reasoning_effort — let the model decide). The rest map
// straight to req_llm's unified reasoning_effort.
const LEVELS: { id: string | null; label: string; hint: string }[] = [
  { id: null, label: "Auto", hint: "Let the model decide (no override)." },
  { id: "minimal", label: "Minimal", hint: "Barely any reasoning — fastest." },
  { id: "low", label: "Low", hint: "A little reasoning." },
  { id: "medium", label: "Medium", hint: "Balanced reasoning." },
  { id: "high", label: "High", hint: "Think hard — slowest, most thorough." },
];

/**
 * Reasoning-effort switch in the composer action row. Passed to the model as
 * req_llm's unified `reasoning_effort` (OpenAI reasoning_effort, Anthropic
 * thinking budget, Google thinking level, …). Only sent when set, so
 * non-reasoning models are unaffected. Renders nothing outside a conversation.
 */
export function ComposerReasoningPicker() {
  const ctx = useContext(ReasoningEffortContext);
  if (!ctx) return null;

  const current = LEVELS.find((l) => l.id === ctx.effort) ?? LEVELS[0];

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          className="flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent"
          title="Reasoning effort"
        >
          <Brain className="size-4" />
          <span>{current.label}</span>
          <ChevronDown className="size-3.5 opacity-60" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent side="top" align="start" className="w-64">
        {LEVELS.map((lvl) => {
          const selected = lvl.id === ctx.effort;
          return (
            <DropdownMenuItem
              key={lvl.id ?? "auto"}
              onSelect={() => ctx.setEffort(lvl.id)}
              className="items-start gap-2.5 py-2"
            >
              <Brain className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5 text-sm font-medium">
                  {lvl.label}
                  {selected && <Check className="size-3.5 text-primary" />}
                </div>
                <div className="text-xs leading-tight text-muted-foreground">{lvl.hint}</div>
              </div>
            </DropdownMenuItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
