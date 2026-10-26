/**
 * Keeps worktrees inside ~/worktrees/<repo>/ by refusing `git worktree add`
 * that would land anywhere else, and branch switches inside one.
 *
 * The layout and the check live in `wt guard`, shared with the Claude Code hook
 * and the pi extension; this file is only opencode's adapter. Throwing blocks
 * the call and hands the model the reason.
 */
import { spawnSync } from "node:child_process";

const fallback = "Blocked: git worktree add outside ~/worktrees/<repo>/. Use `wt create <name>`.";

export default async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    const tool = String(input?.tool ?? "").toLowerCase();
    if (tool !== "bash" && tool !== "shell") return;

    const command = output?.args?.command;
    // Substring test first: spawning wt on every shell call would be waste.
    if (typeof command !== "string" || !/worktree|switch|checkout/.test(command)) return;

    const guard = spawnSync("wt", ["guard", command], { cwd: directory, encoding: "utf8" });
    if (guard.error || guard.status !== 1) return;

    throw new Error(guard.stdout.trim() || fallback);
  },
});
