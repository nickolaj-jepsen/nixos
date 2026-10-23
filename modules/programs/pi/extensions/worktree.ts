/**
 * pi's adapter for `wt`: keeps worktrees inside ~/worktrees/<repo>/, and moves
 * a running session into one.
 *
 * The layout and the guard check live in `wt`, shared with the Claude Code hook
 * and the opencode plugin. The guard blocks instead of rewriting the command,
 * so the model gets the real path back in the reason.
 *
 * pi pins a session's cwd at startup, so a move forks the conversation into a
 * new session file whose header names the worktree and switches to it: pi
 * rebuilds the whole runtime there (tools, context files, footer, git). Only a
 * command context may switch sessions, so the `enter_worktree` tool queues
 * `/wt` for when the turn has settled, and the move then re-prompts the agent.
 * A bare `/wt` asks the naming model for a branch name from the session, so a
 * worktree costs no more than the move.
 */
import { execFile, spawnSync } from "node:child_process";
import { existsSync, statSync, writeFileSync } from "node:fs";
import { basename, isAbsolute } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  isToolCallEventType,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import {
  firstRequest,
  NAME_MAX_TOKENS,
  NAME_MODEL,
  NAME_TIMEOUT_MS,
  namingModel,
  oneLine,
  requests,
  stripRequest,
} from "./lib/naming.ts";
import { recordSideCall } from "./lib/usage-ledger.ts";

const fallback = "Blocked: git worktree add outside ~/worktrees/<repo>/. Use `wt create <name>`.";
const MOVED = "worktree-moved";
// Tools that would still act on the old checkout between enter_worktree and the move.
const MUTATING = new Set(["bash", "bg_run", "edit", "write"]);

// Prompts say what the work is; the branch says the same thing in a name.
const NAME_SYSTEM = `You name a git branch so its owner can tell one worktree from another.
Reply with 2-4 lowercase words joined by hyphens, like "flaky-test-retry". No punctuation, no quotes, no "worktree", no branch prefixes.
Use the user's own words, the directory name and concrete nouns. Name the work, not the fact that you agreed to something.`;
const NAME_WORDS = 4;

const wt = (args: string[], cwd: string) =>
  new Promise<string>((resolve, reject) =>
    execFile("wt", args, { cwd, encoding: "utf8", timeout: 120_000 }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout.trim()),
    ),
  );

const names = (cwd: string) =>
  wt(["names"], cwd).then(
    (out) => out.split("\n").filter(Boolean),
    () => [] as string[],
  );

/** Branch names `wt create` would refuse, so an automatic name has to avoid them. */
const branches = (cwd: string) =>
  new Promise<string[]>((resolve) =>
    execFile(
      "git",
      ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
      { cwd, encoding: "utf8" },
      (error, stdout) => resolve(error ? [] : stdout.split("\n").filter(Boolean)),
    ),
  );

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

/** An existing worktree's path for a name or path; `create` makes a missing name. */
async function resolveWorktree(target: string, cwd: string, create: boolean): Promise<string> {
  if (isAbsolute(target) && existsSync(target) && statSync(target).isDirectory()) return target;
  if ((await names(cwd)).includes(target)) return wt(["cd", target], cwd);
  if (!create) throw new Error(`no worktree named '${target}'`);
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

export default function (pi: ExtensionAPI) {
  // Path the agent asked to move to; set by the tool, consumed once the turn settles.
  let pending: string | undefined;
  // Set just before the queued `/wt` runs, so the move knows to re-prompt the agent.
  let agentMove: string | undefined;

  /** The naming model's branch name, or undefined when it is unavailable or answers nothing usable. */
  const modelName = async (ctx: ExtensionCommandContext) => {
    const model = namingModel(ctx, process.env.PI_WORKTREE_MODEL || NAME_MODEL);
    if (!model) return undefined;
    const lines = [
      `directory: ${basename(ctx.cwd) || ctx.cwd}`,
      "requests:",
      ...requests(ctx, 5, 300).map((prompt) => `- ${prompt}`),
    ];
    try {
      const response = await ctx.modelRegistry
        .streamSimple(
          model,
          {
            systemPrompt: NAME_SYSTEM,
            messages: [
              {
                role: "user",
                content: [{ type: "text", text: lines.join("\n") }],
                timestamp: Date.now(),
              },
            ],
          },
          {
            maxTokens: NAME_MAX_TOKENS,
            temperature: 0,
            timeoutMs: NAME_TIMEOUT_MS,
            // The opencode gateway routes on `x-opencode-session`, which pi derives from this.
            sessionId: ctx.sessionManager.getSessionId(),
          },
        )
        .result();
      recordSideCall(pi, "worktree name", response);
      if (response.stopReason === "error" || response.stopReason === "aborted") return undefined;
      const reply = response.content
        .flatMap((block) => (block.type === "text" ? [block.text] : []))
        .join(" ");
      return slug(reply) || undefined;
    } catch {
      return undefined;
    }
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

  pi.on("tool_call", (event, ctx) => {
    if (pending && MUTATING.has(event.toolName))
      return {
        block: true,
        reason: `This session moves to ${pending} when the turn ends; end your turn now and continue there.`,
      };

    // bg_run (pi-background-tasks) is a shell too.
    const command = isToolCallEventType("bash", event)
      ? event.input.command
      : event.toolName === "bg_run"
        ? event.input.command
        : undefined;
    // Substring test first: spawning wt on every bash call would be waste.
    if (typeof command !== "string" || !command.includes("worktree")) return;

    const guard = spawnSync("wt", ["guard", command], { cwd: ctx.cwd, encoding: "utf8" });
    if (guard.error || guard.status !== 1) return;

    return { block: true, reason: guard.stdout.trim() || fallback };
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
        path = await resolveWorktree(target, ctx.cwd, true);
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

  pi.registerTool({
    name: "enter_worktree",
    label: "Enter worktree",
    description:
      "Create a git worktree (or pick an existing one) and move this session into it, keeping the conversation. " +
      "The worktree starts from the default branch, so uncommitted changes in the current checkout don't come along. " +
      "The move happens when this turn ends: call it alone, before editing anything, and the session continues in the worktree automatically.",
    promptSnippet: "Move this session into its own git worktree before editing",
    promptGuidelines: [
      "Use enter_worktree before your first edit when other agent sessions are active in this checkout and your task edits files; skip it for read-only work.",
      "To work in a worktree use enter_worktree (`wt list` shows existing ones), not `wt create`/`wt cd` in bash: those leave this session in the current checkout.",
      "Leave landing (`wt apply`) and removal (`wt clean`) to your user; end by naming the worktree.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description:
          "Short kebab-case name for the branch and worktree directory, or the name of an existing worktree",
      }),
    }),
    exposure: "model-only",
    // Activated by claude-peers only when the checkout is shared, so a solo clean tree pays nothing.
    defaultActive: false,
    executionMode: "sequential",
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (!ctx.hasUI) throw new Error("enter_worktree needs an interactive session");
      const path = await resolveWorktree(params.name, ctx.cwd, true);
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
