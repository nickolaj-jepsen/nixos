import { basename, dirname, join } from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

/** @gotgenes/pi-subagents writes each child's transcript under `<parent session>/tasks/`. */
const TASKS = "tasks";

/** Whether this session is a subagent's rather than one the user started. */
export const isSubagentSession = (ctx: ExtensionContext) =>
  basename(ctx.sessionManager.getSessionDir()) === TASKS;

/** The directory this session's children write their transcripts to; undefined while unsaved. */
export const childTranscriptDir = (ctx: ExtensionContext) => {
  const file = ctx.sessionManager.getSessionFile();
  return file ? join(dirname(file), basename(file, ".jsonl"), TASKS) : undefined;
};
