import type { I18nKey } from "./i18n";
/**
 * Slash commands available in the composer. This is the single source of truth
 * for both the autocomplete menu (SlashCommandMenu) and the send interceptor
 * (runtime.ts). Backend command handling lives in conversation_channel.ex.
 */
export type SlashCommand = {
  name: string;
  summary: string;
  /** When true, selecting the command only fills "/name " and waits for args
   * instead of submitting immediately. */
  takesArgs?: boolean;
};

export const SLASH_COMMANDS: SlashCommand[] = [
  {
    name: "compact",
    summary: "Summarize older messages to free up context",
  },
  {
    name: "model",
    summary: "Switch the model, e.g. /model openai:gpt-5.4",
    takesArgs: true,
  },
  {
    name: "reload",
    summary: "Reload extensions (pick up newly written ones)",
  },
  {
    name: "rename",
    summary: "Rename this conversation, e.g. /rename 部署调优",
    takesArgs: true,
  },
  {
    name: "loop",
    summary: "Loop a task until done, e.g. /loop 10 fix all tests — /loop stop ends it",
    takesArgs: true,
  },
  {
    name: "help",
    summary: "List the available commands",
  },
];

/** Names of the built-in commands whose summaries have i18n keys (slash.<name>). */
export const BUILTIN_COMMAND_NAMES = new Set(SLASH_COMMANDS.map((c) => c.name));

/**
 * One-line help listing every command, for the /help command. Takes the
 * translator so the list follows the UI language; extension commands are not
 * listed here (they surface in the "/" menu with their own descriptions).
 */
export function slashCommandHelp(t: (key: I18nKey) => string): string {
  return SLASH_COMMANDS.map((c) => `/${c.name} — ${t(`slash.${c.name}` as I18nKey)}`).join(
    "   ·   ",
  );
}

export function matchSlashCommands(text: string, extra: SlashCommand[] = []): SlashCommand[] | null {
  const match = /^\/(\w*)$/.exec(text);
  if (!match) return null;
  const query = match[1].toLowerCase();
  return [...SLASH_COMMANDS, ...extra].filter((command) => command.name.startsWith(query));
}
