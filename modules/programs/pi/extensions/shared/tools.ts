/** `bg_run` (parent/bg.ts): a shell command detached from the turn, so every shell gate checks it too. */
export const BG_RUN = "bg_run";

/** Tools whose `command` runs in a shell. */
export const SHELL_TOOLS: ReadonlySet<string> = new Set(["bash", BG_RUN]);

/** Tools that write a file at their `path`. */
export const WRITE_TOOLS: ReadonlySet<string> = new Set(["edit", "write"]);

/** The command line of a shell tool call, else undefined. */
export const shellCommand = (toolName: string, input: unknown): string | undefined => {
  if (!SHELL_TOOLS.has(toolName)) return undefined;
  const command = (input as { command?: unknown } | undefined)?.command;
  return typeof command === "string" ? command : undefined;
};

/** The path a file-writing tool call targets, else undefined. */
export const writtenPath = (toolName: string, input: unknown): string | undefined => {
  if (!WRITE_TOOLS.has(toolName)) return undefined;
  const args = input as { path?: unknown; file_path?: unknown } | undefined;
  const path = args?.path ?? args?.file_path;
  return typeof path === "string" ? path : undefined;
};
