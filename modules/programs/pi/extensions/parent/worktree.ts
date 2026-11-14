/**
 * pi's adapter for `wt`: moves a running session into a worktree, or back to
 * the repo's primary checkout, and closes the worktree a session leaves or quits
 * in (`wt close --when-free`: uncommitted work becomes a wip commit on the branch,
 * and the folder goes once nothing works in it). Landing stays an explicit `wt land`.
 *
 * pi pins a session's cwd at startup, so a move forks the conversation into a
 * new session file whose header names the target directory and switches to it:
 * pi rebuilds the whole runtime there (tools, context files, footer, git). Only
 * a command context may switch sessions, so the `enter_worktree` and `exit_worktree`
 * tools queue `/wt` or `/back` for when the turn has settled, and the move then
 * re-prompts the agent.
 */
import { execFile } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { Type } from "typebox";
import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  SessionManager,
} from "@earendil-works/pi-coding-agent";

const MOVED = "worktree-moved";
const ENTER_WORKTREE_TOOL = "enter_worktree";
const EXIT_WORKTREE_TOOL = "exit_worktree";

/** Runs `wt`, resolving its stdout; a non-zero exit rejects with what it said on stderr. */
const wt = (args: string[], cwd: string) =>
  new Promise<string>((resolve, reject) =>
    execFile("wt", args, { cwd, encoding: "utf8", timeout: 120_000 }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout.trim()),
    ),
  );

/** Worktree names in this repo, open and closed, for completion and the picker. */
const names = (cwd: string) =>
  wt(["list", "--name"], cwd).then(
    (out) => out.split("\n").filter(Boolean),
    () => [] as string[],
  );

/** A worktree's path for a name: open, reopened, or created off `base` (default: the default branch). */
const resolveWorktree = (target: string, cwd: string, base?: string) =>
  wt(base ? ["new", target, base] : ["new", target], cwd);

/**
 * Closes the worktree at `path` once nothing works in it; `wt` refuses the primary checkout
 * and anything that is not a worktree, which is the common case and not worth reporting.
 */
const closeWhenFree = (path: string) =>
  wt(["close", "--when-free", path], "/").then(
    () => undefined,
    (error: Error) =>
      /primary checkout|not inside a worktree|not inside a git repository|already closed/.test(
        error.message,
      )
        ? undefined
        : error.message,
  );

/** Writes the active branch of the conversation to a new session file rooted at `cwd`. */
function forkInto(ctx: ExtensionCommandContext, cwd: string): string {
  const source = ctx.sessionManager.getSessionFile();
  const target = SessionManager.create(cwd, undefined, {
    parentSession: source && existsSync(source) ? source : undefined,
  });
  const file = target.getSessionFile();
  const header = target.getHeader();
  if (!file || !header) throw new Error("pi could not prepare a session for the worktree");
  const lines = [header, ...ctx.sessionManager.getBranch()].map((entry) => JSON.stringify(entry));
  writeFileSync(file, `${lines.join("\n")}\n`, { flag: "wx", mode: 0o600 });
  return file;
}

/**
 * pi pins the session's cwd in the runtime and never chdirs, so `process.cwd()`
 * and anything `wt` runs with an implicit cwd stay on the checkout the session
 * left — which, for a worktree that is then removed, is a deleted directory.
 */
const follow = (cwd: string) => {
  try {
    process.chdir(cwd);
  } catch {
    // The checkout vanished; pi's tools pass their cwd explicitly and keep working.
  }
};

export default function (pi: ExtensionAPI) {
  // Move the agent asked for: the command to queue and where it goes; consumed once the turn settles.
  let pending: { command: string; path: string } | undefined;
  // The queued command, set just before it runs, so the move knows to re-prompt the agent.
  let agentMove: string | undefined;

  /** Forks the conversation into `path`, switches to it, and reports the move. */
  const moveTo = async (path: string, ctx: ExtensionCommandContext, resume: boolean) => {
    if (path === ctx.cwd) {
      ctx.ui.notify(`Already in ${path}`, "info");
      return;
    }
    let file: string;
    try {
      file = forkInto(ctx, path);
    } catch (error) {
      ctx.ui.notify(`Could not move session: ${(error as Error).message}`, "error");
      return;
    }
    const from = ctx.cwd;
    await ctx.switchSession(file, {
      withSession: async (next) => {
        follow(path);
        next.ui.notify(`Moved session to ${path}`, "info");
        const refused = await closeWhenFree(from);
        if (refused) next.ui.notify(`Left ${from} open: ${refused}`, "warning");
        await next.sendMessage(
          {
            customType: MOVED,
            content:
              `This session moved from ${from} to ${path}; that is now your cwd and workspace. ` +
              `Paths under ${from} belong to the old checkout: don't edit them.` +
              (resume ? " Continue the task here." : ""),
            display: true,
            details: { from, to: path },
          },
          resume ? { triggerTurn: true } : { deliverAs: "nextTurn" },
        );
      },
    });
  };

  // Once, before the first request: a later tool-set change can cost a cache-invalidating
  // re-read. The move needs a UI.
  pi.on("session_start", (_event, ctx) => {
    const active = pi.getActiveTools();
    if (!ctx.hasUI || active.includes(ENTER_WORKTREE_TOOL)) return;
    pi.setActiveTools([...active, ENTER_WORKTREE_TOOL, EXIT_WORKTREE_TOOL]);
  });

  // Quitting inside a worktree closes it; reload, /new, /resume and /fork keep the process going.
  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason === "quit") await closeWhenFree(ctx.cwd);
  });

  // Anything run between the worktree tool and the move would still act on the old checkout.
  pi.on("tool_call", () => {
    if (pending)
      return {
        block: true,
        reason: `This session moves to ${pending.path} when the turn ends; end your turn now and continue there.`,
      };
  });

  pi.on("agent_settled", (event, ctx) => {
    const target = pending;
    pending = undefined;
    if (!target) return;
    if (event.aborted) {
      ctx.ui.notify(`Worktree move cancelled. Run ${target.command} to move later.`, "info");
      return;
    }
    agentMove = target.command;
    // Deferred by pi until agent_settled finishes, then dispatched as a command.
    pi.sendUserMessage(target.command, { expandPromptTemplates: true });
  });

  pi.registerCommand("wt", {
    description:
      "Move this session into a git worktree, creating it if needed: /wt <name> [base]. Without a name it picks an existing worktree.",
    getArgumentCompletions: async (prefix) =>
      (await names(process.cwd()))
        .filter((name) => name.startsWith(prefix))
        .map((name) => ({ value: name, label: name })),
    handler: async (args, ctx) => {
      const resume = agentMove === `/wt ${args.trim()}`;
      agentMove = undefined;
      let [target = "", base] = args.trim().split(/\s+/);
      if (!target) {
        const existing = await names(ctx.cwd);
        if (existing.length === 0) {
          ctx.ui.notify("No worktrees yet; /wt <name> creates one.", "info");
          return;
        }
        const picked = await ctx.ui.select("Worktree", existing);
        if (!picked) return;
        target = picked;
      }

      await ctx.waitForIdle();
      let path: string;
      try {
        path = await resolveWorktree(target, ctx.cwd, base);
      } catch (error) {
        ctx.ui.notify(`Could not enter worktree: ${(error as Error).message}`, "error");
        return;
      }
      await moveTo(path, ctx, resume);
    },
  });

  pi.registerCommand("back", {
    description:
      "Move this session back to the repo's primary checkout, closing the worktree it leaves.",
    handler: async (_args, ctx) => {
      const resume = agentMove === "/back";
      agentMove = undefined;
      await ctx.waitForIdle();
      let path: string;
      try {
        path = await wt(["cd", "--main"], ctx.cwd);
      } catch (error) {
        ctx.ui.notify(`Not in a repo wt knows: ${(error as Error).message}`, "error");
        return;
      }
      await moveTo(path, ctx, resume);
    },
  });

  pi.registerTool({
    name: ENTER_WORKTREE_TOOL,
    label: "Enter worktree",
    description:
      "Create a git worktree (or pick an existing one) and move this session into it, keeping the conversation. " +
      "A new worktree starts from `base`, by default the default branch, so uncommitted changes in the current checkout don't come along. " +
      "Calling it ends your turn; the session then continues in the worktree on its own.",
    promptSnippet: "Move this session into a git worktree of its own",
    promptGuidelines: [
      "Use enter_worktree when the user asks for a worktree, or for more than a quick edit while a peer session works in this checkout (make a quick one in place and tell that peer). Otherwise edit the checkout you are in.",
      "Move with enter_worktree (`wt list` shows existing worktrees), not `wt new`/`wt cd` in bash, which leave this session where it is.",
      "When the work in a worktree is done (committed, and landed with `wt land` if asked), leave it with exit_worktree. `wt land` and `wt close` can't close the worktree this session is in.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description:
          "Short kebab-case name for the branch and worktree directory, or the name of an existing worktree",
      }),
      base: Type.Optional(
        Type.String({
          description: "Ref a new worktree branches from; ignored for an existing one",
        }),
      ),
    }),
    exposure: "model-only",
    // Activated at session_start, only where the move can run.
    defaultActive: false,
    executionMode: "sequential",
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (!ctx.hasUI) throw new Error("enter_worktree needs an interactive session");
      const path = await resolveWorktree(params.name, ctx.cwd, params.base);
      if (path === ctx.cwd) throw new Error(`Already working in ${path}`);
      pending = { command: `/wt ${params.name}`, path };
      return {
        content: [
          {
            type: "text",
            text: `Worktree ready at ${path}. This session moves there when this turn ends; stop now and you will be prompted to continue.`,
          },
        ],
        details: { path },
        terminate: true,
      };
    },
  });

  pi.registerTool({
    name: EXIT_WORKTREE_TOOL,
    label: "Exit worktree",
    description:
      "Move this session back to the repo's primary checkout, keeping the conversation, and close the worktree it leaves. " +
      "Closing commits anything uncommitted as a wip commit and keeps the branch until its work is in the default branch. " +
      "Calling it ends your turn; the session then continues in the primary checkout on its own.",
    promptSnippet: "Leave this git worktree for the primary checkout, closing it",
    parameters: Type.Object({}),
    exposure: "model-only",
    // Activated at session_start, only where the move can run.
    defaultActive: false,
    executionMode: "sequential",
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      if (!ctx.hasUI) throw new Error("exit_worktree needs an interactive session");
      const path = await wt(["cd", "--main"], ctx.cwd);
      if (path === ctx.cwd) throw new Error("Not in a worktree: this is the primary checkout");
      pending = { command: "/back", path };
      return {
        content: [
          {
            type: "text",
            text: `This session moves to ${path} when this turn ends, and the worktree closes; stop now and you will be prompted to continue.`,
          },
        ],
        details: { path },
        terminate: true,
      };
    },
  });
}
