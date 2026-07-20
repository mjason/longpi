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
    name: "help",
    summary: "List the available commands",
  },
];

export const SLASH_COMMAND_NAMES = SLASH_COMMANDS.map((c) => c.name);

/**
 * Returns the commands to suggest for the current composer text, or null when
 * the text is not a bare slash-command token (e.g. it has a space, so the
 * command is already chosen and the user is typing arguments).
 */
/** One-line help listing every command, for the /help command. */
export function slashCommandHelp(): string {
  return SLASH_COMMANDS.map((c) => `/${c.name} — ${c.summary}`).join("   ·   ");
}

export function matchSlashCommands(text: string): SlashCommand[] | null {
  const match = /^\/(\w*)$/.exec(text);
  if (!match) return null;
  const query = match[1].toLowerCase();
  return SLASH_COMMANDS.filter((command) => command.name.startsWith(query));
}
