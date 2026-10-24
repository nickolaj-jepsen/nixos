/**
 * What happens to the worktree a session is sitting in when pi exits.
 *
 * Nothing pi exposes can ask *before* an exit: `/quit`, ctrl+d and ctrl+c stop
 * the TUI and only then emit `session_shutdown`, and a closed window signals a
 * pty that is already gone. One narrow opening is left — the signal path
 * disposes extensions *before* tearing the terminal down — so the hook asks only
 * when the TUI is provably still alive (`process.stdin.isRaw`), and otherwise
 * applies `wt`'s own safety rule: a worktree that is clean, has nothing ahead of
 * the default branch, and has nobody's cwd inside it is removed; everything
 * else is left alone.
 *
 * The dialog and its rules live in `lib/park.ts`, shared with `/back`, which
 * asks the same question when a session moves out of a worktree rather than
 * ending in one.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { park, report, sessionWorktree } from "./lib/park.ts";

/** A window that is already closing does not get to hold the process for long. */
const ASK_MS = 5_000;

export default function (pi: ExtensionAPI) {
  pi.on("session_shutdown", async (event, ctx) => {
    // A move, fork, resume, new session or reload also shuts the old session
    // down. Those are not exits — `/wt`/`/back` in particular are moving the
    // session to another checkout.
    if (event.reason !== "quit" || ctx.mode !== "tui") return;
    const found = await sessionWorktree(ctx.cwd);
    if (!found) return;

    const result = await park(pi, ctx, found.repo, found.tree, {
      quietSafe: true,
      // Every other exit has no TUI left to draw in; keep the worktree.
      noDialog: process.stdin.isRaw !== true,
      signal: AbortSignal.timeout(ASK_MS),
    });
    if (result) report(ctx, result.text, result.type);
  });
}
