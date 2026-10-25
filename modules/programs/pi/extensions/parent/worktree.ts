/**
 * pi's adapter for `wt`: moves a running session into a worktree — or back out
 * to the repo's primary checkout, which is what `/new` does when it runs inside
 * a worktree. The guard on where worktrees go is ../core/worktree-guard.ts.
 *
 * pi pins a session's cwd at startup, so a move forks the conversation into a
 * new session file whose header names the worktree and switches to it: pi
 * rebuilds the whole runtime there (tools, context files, footer, git). Only a
 * command context may switch sessions, so the `enter_worktree` tool queues
 * `/wt` for when the turn has settled, and the move then re-prompts the agent.
 * A bare `/wt` asks the naming model for a branch name from the session, so a
 * worktree costs no more than the move. `/back` runs the same machinery the
 * other way and then asks what should become of the worktree left behind;
 * quitting pi inside a worktree removes it only when `wt clean` would.
 */
import { existsSync, statSync, writeFileSync } from "node:fs";
import { basename, isAbsolute } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { Box, Text } from "@earendil-works/pi-tui";
import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import {
  firstRequest,
  NAME_MAX_TOKENS,
  NAME_TIMEOUT_MS,
  oneLine,
  requests,
  stripRequest,
} from "../shared/naming.ts";
import { isLeanModel } from "../shared/lean-model.ts";
import { SHELL_TOOLS, WRITE_TOOLS } from "../shared/tools.ts";
import { linkedWorktree, park, removableAt, sessionWorktree, worktreeAt } from "./lib/park.ts";
import { sideCall } from "../shared/side-call.ts";
import { branches, ENTER_WORKTREE_TOOL, names, status, wt, type RepoStatus } from "./lib/wt.ts";

const MOVED = "worktree-moved";
const PARKED = "worktree-parked";
// Tools that would still act on the old checkout between enter_worktree and the move.
const MUTATING = new Set([...SHELL_TOOLS, ...WRITE_TOOLS]);

/** What `/back` leaves in the transcript: where the session went and what became of the worktree. */
type ParkedDetails = { from: string; to: string; worktree: string; outcome: string };

// Prompts say what the work is; the branch says the same thing in a name.
const NAME_SYSTEM = `You name a git branch so its owner can tell one worktree from another.
Reply with 2-4 lowercase words joined by hyphens, like "flaky-test-retry". No punctuation, no quotes, no "worktree", no branch prefixes.
Use the user's own words, the directory name and concrete nouns. Name the work, not the fact that you agreed to something.`;
const NAME_WORDS = 4;

/** Turns a model reply into a branch name: lowercase words, `NAME_WORDS` at most. */
const slug = (raw: string) =>
  oneLine(raw)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(" ")
    .filter(Boolean)
    .slice(0, NAME_WORDS)
    .join("-");

/** `base`, or `base-2`, `base-3`, … — whichever nothing claims yet. */
const free = (base: string, claimed: Set<string>) => {
  let candidate = base;
  for (let n = 2; claimed.has(candidate); n++) candidate = `${base}-${n}`;
  return candidate;
};

/** A worktree's path for a name or path, creating a missing name. */
async function resolveWorktree(target: string, cwd: string): Promise<string> {
  if (isAbsolute(target) && existsSync(target) && statSync(target).isDirectory()) return target;
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

/** Writes a session file that holds only a header, so the conversation starts empty at `cwd`. */
function freshInto(cwd: string): string {
  const target = SessionManager.create(cwd);
  const file = target.getSessionFile();
  const header = target.getHeader();
  if (!file || !header) throw new Error(`pi could not prepare a session for ${cwd}`);
  writeFileSync(file, `${JSON.stringify(header)}\n`, { flag: "wx", mode: 0o600 });
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
  // Path the agent asked to move to; set by the tool, consumed once the turn settles.
  let pending: string | undefined;
  // Set just before the queued `/wt` runs, so the move knows to re-prompt the agent.
  let agentMove: string | undefined;

  /** The naming model's branch name, or undefined when it is unavailable or answers nothing usable. */
  const modelName = async (ctx: ExtensionCommandContext) => {
    const reply = await sideCall(pi, ctx, {
      source: "worktree name",
      system: NAME_SYSTEM,
      prompt: [
        `directory: ${basename(ctx.cwd) || ctx.cwd}`,
        "requests:",
        ...requests(ctx, 5, 300).map((prompt) => `- ${prompt}`),
      ].join("\n"),
      maxTokens: NAME_MAX_TOKENS,
      timeoutMs: NAME_TIMEOUT_MS,
    });
    return "text" in reply ? slug(reply.text) || undefined : undefined;
  };

  /**
   * A branch name for the work in this session. A bare `/wt` is worth the round
   * trip; when the model is unreachable the first prompt names it instead.
   */
  const generateName = async (ctx: ExtensionCommandContext) =>
    free(
      (await modelName(ctx)) || slug(stripRequest(firstRequest(ctx) ?? "")) || "worktree",
      new Set([...(await names(ctx.cwd)), ...(await branches(ctx.cwd))]),
    );

  // Once, before the first request: a later tool-set change can cost a cache-invalidating
  // re-read. The move needs a UI, and a local model's window has no room to spare.
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI || isLeanModel(ctx.model) || pi.getActiveTools().includes(ENTER_WORKTREE_TOOL))
      return;
    pi.setActiveTools([...pi.getActiveTools(), ENTER_WORKTREE_TOOL]);
  });

  // A move, fork, resume, new session or reload also shuts the session down; only an exit
  // leaves the worktree behind, and there is no TUI left to ask in.
  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason !== "quit" || ctx.mode !== "tui") return;
    const found = await sessionWorktree(ctx.cwd);
    const main = found?.repo.worktrees.find((tree) => tree.isMain);
    if (!found?.tree.safeToRemove || !main) return;
    await wt(["clean", found.tree.name], main.path).catch(() => {});
  });

  pi.on("tool_call", (event) => {
    if (pending && MUTATING.has(event.toolName))
      return {
        block: true,
        reason: `This session moves to ${pending} when the turn ends; end your turn now and continue there.`,
      };
  });

  pi.on("agent_settled", (event, ctx) => {
    const target = pending;
    pending = undefined;
    if (!target) return;
    if (event.aborted) {
      const name = basename(target);
      ctx.ui.notify(
        `Worktree move cancelled; ${name} was kept. Run /wt ${name} to move later.`,
        "info",
      );
      return;
    }
    agentMove = target;
    // Deferred by pi until agent_settled finishes, then dispatched as a command.
    pi.sendUserMessage(`/wt ${target}`, { expandPromptTemplates: true });
  });

  // `/new` (and `/clear`, which calls the same runtime method) roots its session
  // in the runtime's pinned cwd, and `session_before_switch` can only cancel —
  // there is no cwd override to give it. So the move back out is dispatched as
  // our own command, after the cancelled one has returned.
  pi.on("session_before_switch", async (event, ctx) => {
    if (event.reason !== "new" || !(await linkedWorktree(ctx.cwd))) return;
    setTimeout(() => {
      pi.sendUserMessage("/back --new", { expandPromptTemplates: true });
    }, 0);
    return { cancel: true };
  });

  pi.registerCommand("wt", {
    description:
      "Move this session into a git worktree, creating it if needed: /wt <name>. Without a name it generates one from the session.",
    getArgumentCompletions: async (prefix) =>
      (await names(process.cwd()))
        .filter((name) => name.startsWith(prefix))
        .map((name) => ({ value: name, label: name })),
    handler: async (args, ctx) => {
      const resume = agentMove !== undefined && agentMove === args.trim();
      agentMove = undefined;
      const target = args.trim() || (await generateName(ctx));

      await ctx.waitForIdle();
      let path: string;
      let file: string;
      try {
        path = await resolveWorktree(target, ctx.cwd);
        if (path === ctx.cwd) {
          ctx.ui.notify(`Already in ${path}`, "info");
          return;
        }
        file = forkInto(ctx, path);
      } catch (error) {
        ctx.ui.notify(`Could not move to worktree: ${(error as Error).message}`, "error");
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
                `This session moved from ${from} to the git worktree ${path}; that is now your cwd and workspace. ` +
                `Paths under ${from} belong to the old checkout: don't edit them.` +
                (resume ? " Continue the task here." : ""),
              display: true,
              details: { from, to: path },
            },
            resume ? { triggerTurn: true } : { deliverAs: "nextTurn" },
          );
        },
      });
    },
  });

  /**
   * The way out of a worktree: back to the repo's primary checkout, then the
   * parked-worktree question. `--new` is what `/new` becomes inside a worktree —
   * the same move with a fresh conversation instead of this one.
   */
  pi.registerCommand("back", {
    description:
      "Move this session back to the repo's primary checkout, then ask whether to land or remove the worktree you left: /back. With --new it starts a fresh session there, which is what /new does inside a worktree.",
    handler: async (args, ctx) => {
      const fresh = args.split(/\s+/).includes("--new");
      await ctx.waitForIdle();

      let repo: RepoStatus;
      try {
        repo = await status(ctx.cwd);
      } catch (error) {
        ctx.ui.notify(`Not in a repo wt knows: ${(error as Error).message}`, "error");
        return;
      }
      const main = repo.worktrees.find((tree) => tree.isMain);
      const here = worktreeAt(repo, ctx.cwd);
      if (!main || !here) {
        ctx.ui.notify("Already in the primary checkout", "info");
        return;
      }

      // Looked up before the switch: afterwards `ctx.cwd` is the primary checkout.
      const left = removableAt(repo, ctx.cwd);
      let file: string;
      try {
        file = fresh ? freshInto(main.path) : forkInto(ctx, main.path);
      } catch (error) {
        ctx.ui.notify(`Could not move to ${main.path}: ${(error as Error).message}`, "error");
        return;
      }

      // The question has to be asked while this session's context is still live: a
      // captured ctx goes stale the moment the switch lands, and the dialog would be
      // drawn on a UI that the replacement then wipes. So park first, move second —
      // and report the outcome as an entry in the session that arrives.
      const from = ctx.cwd;
      // Before the question, not after: the answer may remove the directory this
      // process is standing in.
      follow(main.path);
      const parked = left ? await park(pi, ctx, left) : undefined;

      await ctx.switchSession(file, {
        withSession: async (next) => {
          if (!parked || !left) return;
          const details: ParkedDetails = {
            from,
            to: main.path,
            worktree: left.name,
            outcome: parked,
          };
          await next.sendMessage({
            customType: PARKED,
            content: parked,
            display: true,
            details,
          });
        },
      });
    },
  });

  // One line of housekeeping does not need the default custom-message wrapper.
  pi.registerMessageRenderer<ParkedDetails>(PARKED, (message, { outputPad }, theme) => {
    const outcome = message.details?.outcome;
    if (!outcome) return undefined;
    const box = new Box(outputPad, 0);
    box.addChild(new Text(`${theme.fg("dim", "› ")}${theme.fg("muted", outcome)}`, 0, 0));
    return box;
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
      "When your user asks to commit to main from a worktree, commit in the worktree, then run `wt apply <name>`; if wt refuses, report its reason instead of landing another way (no `git push`, no merge from the primary checkout).",
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
      pending = path;
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
