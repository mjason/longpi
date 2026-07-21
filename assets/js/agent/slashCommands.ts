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
    name: "help",
    summary: "List the available commands",
  },
];

/** One-line help listing every command, for the /help command. */
export function slashCommandHelp(): string {
  return SLASH_COMMANDS.map((c) => `/${c.name} — ${c.summary}`).join("   ·   ");
}

export function matchSlashCommands(text: string, extra: SlashCommand[] = []): SlashCommand[] | null {
  const match = /^\/(\w*)$/.exec(text);
  if (!match) return null;
  const query = match[1].toLowerCase();
  return [...SLASH_COMMANDS, ...extra].filter((command) => command.name.startsWith(query));
}
