/** The command line of a shell tool call, else undefined. */
export const shellCommand = (toolName: string, input: unknown): string | undefined => {
  if (toolName !== "bash") return undefined;
  const command = (input as { command?: unknown } | undefined)?.command;
  return typeof command === "string" ? command : undefined;
};
