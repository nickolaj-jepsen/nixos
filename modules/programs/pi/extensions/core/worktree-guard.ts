/**
 * Keeps worktrees inside ~/worktrees/<repo>/. The layout and the guard check
 * live in `wt`, shared with the Claude Code hook and the opencode plugin. The
 * guard blocks instead of rewriting the command, so the model gets the real
 * path back in the reason.
 */
import { execFile } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { shellCommand } from "../shared/tools.ts";

const fallback = "Blocked: git worktree add outside ~/worktrees/<repo>/. Use `wt create <name>`.";

/** `wt guard`'s exit status (undefined when it didn't run) and stdout; async so subagents sharing the loop don't freeze. */
const guard = (command: string, cwd: string) =>
  new Promise<{ status?: number; stdout: string }>((resolve) =>
    execFile("wt", ["guard", command], { cwd, encoding: "utf8" }, (error, stdout) =>
      resolve({
        status: !error ? 0 : typeof error.code === "number" ? error.code : undefined,
        stdout,
      }),
    ),
  );

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const command = shellCommand(event.toolName, event.input);
    // Substring test first: spawning wt on every bash call would be waste.
    if (!command?.includes("worktree")) return;

    const { status, stdout } = await guard(command, ctx.cwd);
    if (status !== 1) return;

    return { block: true, reason: stdout.trim() || fallback };
  });
}
