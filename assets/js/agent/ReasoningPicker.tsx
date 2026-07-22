import { Brain, Check, ChevronDown } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "../components/ui/dropdown-menu";
import { type I18nKey, useI18n } from "./i18n";
import { useConversationStore } from "./store";

// null = "Auto" (send no reasoning_effort — let the model decide). The rest map
// straight to req_llm's unified reasoning_effort.
const LEVELS: { id: string | null; label: I18nKey; hint: I18nKey }[] = [
  { id: null, label: "reasoning.auto", hint: "reasoning.autoHint" },
  { id: "minimal", label: "reasoning.minimal", hint: "reasoning.minimalHint" },
  { id: "low", label: "reasoning.low", hint: "reasoning.lowHint" },
  { id: "medium", label: "reasoning.medium", hint: "reasoning.mediumHint" },
  { id: "high", label: "reasoning.high", hint: "reasoning.highHint" },
];

/**
 * Reasoning-effort switch in the composer action row. Passed to the model as
 * req_llm's unified `reasoning_effort` (OpenAI reasoning_effort, Anthropic
 * thinking budget, Google thinking level, …). Only sent when set, so
 * non-reasoning models are unaffected. Renders nothing outside a conversation.
 */
export function ComposerReasoningPicker() {
  const { t } = useI18n();
  const effort = useConversationStore((s) => s.reasoningEffort);
  const setEffort = useConversationStore((s) => s.setReasoning);

  const current = LEVELS.find((l) => l.id === effort) ?? LEVELS[0];

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          className="flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent"
          title={t("composer.reasoning")}
        >
          <Brain className="size-4" />
          <span>{t(current.label)}</span>
          <ChevronDown className="size-3.5 opacity-60" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent side="top" align="start" className="w-64">
        {LEVELS.map((lvl) => {
          const selected = lvl.id === effort;
          return (
            <DropdownMenuItem
              key={lvl.id ?? "auto"}
              onSelect={() => setEffort(lvl.id)}
              className="items-start gap-2.5 py-2"
            >
              <Brain className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5 text-sm font-medium">
                  {t(lvl.label)}
                  {selected && <Check className="size-3.5 text-primary" />}
                </div>
                <div className="text-xs leading-tight text-muted-foreground">{t(lvl.hint)}</div>
              </div>
            </DropdownMenuItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
