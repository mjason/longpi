import { useAuiState, useComposerRuntime } from "@assistant-ui/react";
import { useEffect, useMemo, useState } from "react";
import { cn } from "../lib/utils";
import { useConversationStore } from "./store";
import { type I18nKey, useI18n } from "./i18n";
import { BUILTIN_COMMAND_NAMES, matchSlashCommands, type SlashCommand } from "./slashCommands";

/**
 * Autocomplete for slash commands, rendered inside the (relative) composer root
 * and anchored just above the input. Appears while the composer holds a bare
 * "/command" token; keyboard navigation is captured before the composer's own
 * Enter-to-send handler so selecting a command doesn't also send raw text.
 */
export function SlashCommandMenu() {
  const { t } = useI18n();
  const text = useAuiState((s) => s.composer.text);
  const composer = useComposerRuntime();
  const extCommands = useConversationStore((s) => s.commands);
  const extAsSlash = useMemo<SlashCommand[]>(
    () => extCommands.map((c) => ({ name: c.name, summary: c.description })),
    [extCommands],
  );
  const matches = useMemo(() => matchSlashCommands(text, extAsSlash), [text, extAsSlash]);
  const open = matches !== null && matches.length > 0;
  const [active, setActive] = useState(0);

  // Reset the highlight whenever the query changes so it never points past the
  // filtered list.
  useEffect(() => setActive(0), [text]);

  useEffect(() => {
    if (!open || !matches) return;
    const list = matches;

    function select(command: SlashCommand) {
      if (command.takesArgs) {
        composer.setText(`/${command.name} `);
        return;
      }
      composer.setText(`/${command.name}`);
      composer.send();
    }

    // Capture phase so we win over the composer's bubble-phase Enter handler.
    function onKeyDown(event: KeyboardEvent) {
      switch (event.key) {
        case "ArrowDown":
          event.preventDefault();
          setActive((i) => (i + 1) % list.length);
          break;
        case "ArrowUp":
          event.preventDefault();
          setActive((i) => (i - 1 + list.length) % list.length);
          break;
        case "Enter":
        case "Tab":
          event.preventDefault();
          event.stopPropagation();
          select(list[Math.min(active, list.length - 1)]);
          break;
        case "Escape":
          event.preventDefault();
          event.stopPropagation();
          composer.setText("");
          break;
      }
    }

    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [open, matches, active, composer]);

  if (!open || !matches) return null;

  return (
    <div
      role="listbox"
      className="absolute bottom-full left-0 z-20 mb-2 w-full overflow-hidden rounded-xl bg-popover p-1 shadow-[0_12px_40px_-8px_rgba(0,0,0,0.18),0_2px_10px_-2px_rgba(0,0,0,0.08)] ring-1 ring-black/[0.06] dark:shadow-[0_12px_40px_-8px_rgba(0,0,0,0.5)] dark:ring-white/[0.08]"
    >
      {matches.map((command, i) => (
        <button
          key={command.name}
          type="button"
          role="option"
          aria-selected={i === active}
          // Prevent the input from losing focus on click.
          onMouseDown={(e) => e.preventDefault()}
          onMouseEnter={() => setActive(i)}
          onClick={() => {
            if (command.takesArgs) {
              composer.setText(`/${command.name} `);
            } else {
              composer.setText(`/${command.name}`);
              composer.send();
            }
          }}
          className={cn(
            "flex w-full items-baseline gap-3 rounded-lg px-3 py-2 text-left transition-colors",
            i === active ? "bg-accent" : "hover:bg-accent/50",
          )}
        >
          <span className="font-mono text-sm font-medium text-foreground">/{command.name}</span>
          <span className="min-w-0 flex-1 truncate text-xs text-muted-foreground">
            {BUILTIN_COMMAND_NAMES.has(command.name)
              ? t(`slash.${command.name}` as I18nKey)
              : command.summary}
          </span>
        </button>
      ))}
    </div>
  );
}
