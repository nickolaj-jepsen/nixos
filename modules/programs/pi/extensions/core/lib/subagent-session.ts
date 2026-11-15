import { basename } from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

/** @gotgenes/pi-subagents writes each child's transcript under `<parent session>/tasks/`. */
const TASKS = "tasks";

/** Whether this session is a subagent's rather than one the user started. */
export const isSubagentSession = (ctx: ExtensionContext) =>
  basename(ctx.sessionManager.getSessionDir()) === TASKS;
