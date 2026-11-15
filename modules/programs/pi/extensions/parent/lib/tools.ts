/** `bg_run` (../bg.ts): a shell command detached from the turn. */
export const BG_RUN = "bg_run";

/** Tools whose `command` runs in a shell. */
const SHELL_TOOLS: ReadonlySet<string> = new Set(["bash", BG_RUN]);

/** The command line of a shell tool call, else undefined. */
export const shellCommand = (toolName: string, input: unknown): string | undefined => {
  if (!SHELL_TOOLS.has(toolName)) return undefined;
  const command = (input as { command?: unknown } | undefined)?.command;
  return typeof command === "string" ? command : undefined;
};
