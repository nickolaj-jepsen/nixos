/**
 * pi's adapter for `wt`: moves a running session into a worktree, or back to
 * the repo's primary checkout. It never commits, lands, or removes worktrees;
 * those stay explicit `git`/`wt` commands for the agent or user.
 *
 * pi pins a session's cwd at startup, so a move forks the conversation into a
 * new session file whose header names the target directory and switches to it:
 * pi rebuilds the whole runtime there (tools, context files, footer, git). Only
 * a command context may switch sessions, so the `enter_worktree` tool queues
 * `/wt` for when the turn has settled, and the move then re-prompts the agent.
 */
import { execFile } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { Type } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import { isLeanModel } from "../shared/lean-model.ts";
import { SHELL_TOOLS, WRITE_TOOLS } from "../shared/tools.ts";

const MOVED = "worktree-moved";
const ENTER_WORKTREE_TOOL = "enter_worktree";
// Tools that would still act on the old checkout between enter_worktree and the move.
const MUTATING = new Set([...SHELL_TOOLS, ...WRITE_TOOLS]);

/** Runs `wt`, resolving its stdout; a non-zero exit rejects with what it said on stderr. */
const wt = (args: string[], cwd: string) =>
  new Promise<string>((resolve, reject) =>
    execFile("wt", args, { cwd, encoding: "utf8", timeout: 120_000 }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout.trim()),
    ),
  );

/** Worktree names in this repo, for completion and the picker. */
const names = (cwd: string) =>
  wt(["names"], cwd).then(
    (out) => out.split("\n").filter(Boolean),
    () => [] as string[],
  );

/** A worktree's path for a name, creating the worktree when the name is new. */
async function resolveWorktree(target: string, cwd: string): Promise<string> {
  if ((await names(cwd)).includes(target)) return wt(["cd", target], cwd);
  return wt(["create", target], cwd);
}

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
  // Worktree the agent asked to move to; set by the tool, consumed once the turn settles.
  let pending: { name: string; path: string } | undefined;
  // Set just before the queued `/wt` runs, so the move knows to re-prompt the agent.
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
  // re-read. The move needs a UI, and a local model's window has no room to spare.
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI || isLeanModel(ctx.model) || pi.getActiveTools().includes(ENTER_WORKTREE_TOOL))
      return;
    pi.setActiveTools([...pi.getActiveTools(), ENTER_WORKTREE_TOOL]);
  });

  pi.on("tool_call", (event) => {
    if (pending && MUTATING.has(event.toolName))
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
      ctx.ui.notify(
        `Worktree move cancelled; ${target.name} was kept. Run /wt ${target.name} to move later.`,
        "info",
      );
      return;
    }
    agentMove = target.name;
    // Deferred by pi until agent_settled finishes, then dispatched as a command.
    pi.sendUserMessage(`/wt ${target.name}`, { expandPromptTemplates: true });
  });

  pi.registerCommand("wt", {
    description:
      "Move this session into a git worktree, creating it if needed: /wt <name>. Without a name it picks an existing worktree.",
    getArgumentCompletions: async (prefix) =>
      (await names(process.cwd()))
        .filter((name) => name.startsWith(prefix))
        .map((name) => ({ value: name, label: name })),
    handler: async (args, ctx) => {
      const resume = agentMove !== undefined && agentMove === args.trim();
      agentMove = undefined;
      let target = args.trim();
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
        path = await resolveWorktree(target, ctx.cwd);
      } catch (error) {
        ctx.ui.notify(`Could not enter worktree: ${(error as Error).message}`, "error");
        return;
      }
      await moveTo(path, ctx, resume);
    },
  });

  pi.registerCommand("back", {
    description:
      "Move this session back to the repo's primary checkout. The worktree you leave stays as it is.",
    handler: async (_args, ctx) => {
      await ctx.waitForIdle();
      let path: string;
      try {
        path = await wt(["cd", "--main"], ctx.cwd);
      } catch (error) {
        ctx.ui.notify(`Not in a repo wt knows: ${(error as Error).message}`, "error");
        return;
      }
      await moveTo(path, ctx, false);
    },
  });

  pi.registerTool({
    name: ENTER_WORKTREE_TOOL,
    label: "Enter worktree",
    description:
      "Create a git worktree (or pick an existing one) and move this session into it, keeping the conversation. " +
      "The worktree starts from the default branch, so uncommitted changes in the current checkout don't come along. " +
      "The move happens when this turn ends: call it alone, before editing anything, and the session continues in the worktree automatically.",
    promptSnippet: "Move this session into its own git worktree before editing",
    promptGuidelines: [
      "Use enter_worktree before your first edit when other agent sessions are active in this checkout and your task edits files; skip it for read-only work.",
      "To work in a worktree use enter_worktree (`wt list` shows existing ones), not `wt create`/`wt cd` in bash: those leave this session in the current checkout.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description:
          "Short kebab-case name for the branch and worktree directory, or the name of an existing worktree",
      }),
    }),
    exposure: "model-only",
    // Activated at session_start, only where the move can run.
    defaultActive: false,
    executionMode: "sequential",
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (!ctx.hasUI) throw new Error("enter_worktree needs an interactive session");
      const path = await resolveWorktree(params.name, ctx.cwd);
      if (path === ctx.cwd) throw new Error(`Already working in ${path}`);
      pending = { name: params.name, path };
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
}
