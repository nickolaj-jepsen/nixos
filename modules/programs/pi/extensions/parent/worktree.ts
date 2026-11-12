/**
 * pi's adapter for worktrunk's `wt`: moves a running session into a git worktree,
 * or back to the repo's primary checkout, and removes the worktree a session
 * leaves or quits in once it is clean and nothing else works there. Landing stays
 * an explicit `wt merge`.
 *
 * pi pins a session's cwd at startup, so a move forks the conversation into a
 * new session file whose header names the target directory and switches to it:
 * pi rebuilds the whole runtime there (tools, context files, footer, git). Only
 * a command context may switch sessions, so the `enter_worktree` tool queues
 * `/wt` for when the turn has settled, and the move then re-prompts the agent.
 */
import { execFile } from "node:child_process";
import { existsSync, readdirSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import { Type } from "typebox";
import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import { isLeanModel } from "../shared/lean-model.ts";
import { ENTER_WORKTREE, SHELL_TOOLS, WRITE_TOOLS } from "../shared/tools.ts";
import type { HubRow } from "./lib/protocol.gen.ts";
import type { Services } from "./services.ts";

const MOVED = "worktree-moved";
// Tools that would still act on the old checkout between enter_worktree and the move.
const MUTATING = new Set([...SHELL_TOOLS, ...WRITE_TOOLS]);
// A branch worktrunk has never seen is the one case `--create` is for.
const NO_BRANCH = /no branch named/i;
// A harness, by command line: `…/bin/pi`, `…/bin/claude`, or their store paths.
const AGENT = /(^|\/)(pi|claude)( |$)|pi-coding-agent|claude-code/;
// worktrunk refusing to remove a worktree it found uncommitted work in.
const DIRTY = /has uncommitted changes/i;
// Nothing to close: not a worktree of this repo, or one that is already gone.
const NOT_OURS = /no branch named|not a git repository|already removed|does not exist/i;

/** A worktree `wt list` reports: its branch, its directory, and whether it is the primary checkout. */
type Worktree = { branch: string; path: string; main: boolean };
/** One row of `wt list --format=json`, as far as this feature reads it. */
type Listed = { branch?: string | null; worktree?: { path?: string; main?: boolean } | null };
/** `wt switch --format=json`, with `--create` when it made the branch. */
type Switched = { action: "created" | "existing" | "already_at"; branch: string; path: string };
/** `wt remove --format=json`, one per removal. */
type Removal = { branch?: string | null; branch_outcome?: string };
/** Something to tell the user; `warning` when it is about work left behind. */
type Notice = { text: string; warning: boolean };

/** Runs `wt`, resolving its stdout; a non-zero exit rejects with what it said on stderr. */
const wt = (args: string[], cwd: string) =>
  new Promise<string>((resolve, reject) =>
    execFile("wt", args, { cwd, encoding: "utf8", timeout: 120_000 }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout.trim()),
    ),
  );

/**
 * The JSON `wt` printed: all of stdout for `list`, one line for a command whose
 * hooks printed around it.
 */
const json = <T>(stdout: string): T | undefined => {
  for (const candidate of [stdout, ...stdout.split("\n").reverse()]) {
    try {
      const parsed: unknown = JSON.parse(candidate);
      if (typeof parsed === "object" && parsed !== null) return parsed as T;
    } catch {
      // Not JSON; the next candidate might be.
    }
  }
  return undefined;
};

/** Whether `at` is `path` or somewhere under it. */
const inside = (at: string, path: string) => at === path || at.startsWith(`${path}/`);

/** The worktrees of this repo, primary checkout included. */
const worktrees = async (cwd: string): Promise<Worktree[]> => {
  const listed = json<{ items?: Listed[] }>(await wt(["list", "--format=json"], cwd));
  return (listed?.items ?? []).flatMap(({ branch, worktree }) =>
    branch && worktree?.path ? [{ branch, path: worktree.path, main: worktree.main === true }] : [],
  );
};

/** The branches this repo has a worktree for, for completion and the picker. */
const names = (cwd: string) =>
  worktrees(cwd).then(
    (all) => all.filter((worktree) => !worktree.main).map((worktree) => worktree.branch),
    () => [] as string[],
  );

/** The repo's primary checkout: the worktree worktrunk marks as main. */
const primaryPath = async (cwd: string) => {
  const main = (await worktrees(cwd)).find((worktree) => worktree.main);
  if (!main) throw new Error("no primary checkout in wt list");
  return main.path;
};

/**
 * Copies the gitignored paths the primary checkout's `.worktreeinclude` lists
 * into a worktree this feature just made, so the session can build and test
 * there: those files are in no commit. Resolves with why it failed, if it did.
 */
const copyIgnored = (path: string) =>
  wt(["step", "copy-ignored", "--require-include"], path).then(
    () => undefined,
    (error: Error) => error.message.split("\n")[0],
  );

/**
 * Switches to `target`, making its worktree when it has none, and the branch off
 * `base` (worktrunk's default branch by default) when it has no branch either.
 * `--no-cd` leaves directory changes to the move, which has to fork the session
 * there anyway. A worktree it makes gets the ignored files it would otherwise
 * lack; `copyFailed` says why that did not work, if it did not.
 */
const switchTo = async (
  target: string,
  cwd: string,
  base?: string,
): Promise<Switched & { copyFailed?: string }> => {
  const run = async (extra: string[]) => {
    const switched = json<Switched>(
      await wt(["switch", target, "--no-cd", "--format=json", ...extra], cwd),
    );
    if (!switched?.path) throw new Error(`wt switch ${target} named no worktree`);
    return switched;
  };
  let switched: Switched;
  try {
    switched = await run([]);
  } catch (error) {
    if (!NO_BRANCH.test((error as Error).message)) throw error;
    switched = await run(["--create", ...(base ? ["--base", base] : [])]);
  }
  if (switched.action !== "created") return switched;
  return { ...switched, copyFailed: await copyIgnored(switched.path) };
};

/**
 * Who else works in `path`, if anyone. The hub lists every live pi and Claude
 * Code session on this host, but its own `session_shutdown` handler runs before a
 * feature's and takes its rows with it, so the feature keeps the last publish.
 * Without a hub, the processes' own directories answer the same question on
 * Linux; a worktree's marker cannot, being this session's own as often as not.
 */
const whoIsWorking = (path: string, peers: readonly HubRow[], self: string | undefined) => {
  const peer = peers.find((row) => row.id !== self && !row.host && inside(row.cwd, path));
  if (peer) return peer.name || peer.agent;
  if (process.platform !== "linux") return undefined;
  let pids: string[];
  try {
    pids = readdirSync("/proc");
  } catch {
    return undefined;
  }
  for (const pid of pids) {
    if (!/^\d+$/.test(pid) || Number(pid) === process.pid) continue;
    const dir = `/proc/${pid}`;
    try {
      if (!inside(readlinkSync(`${dir}/cwd`), path)) continue;
      const command = readFileSync(`${dir}/cmdline`, "utf8").replaceAll("\0", " ").trim();
      if (AGENT.test(command)) return command.split(" ")[0].split("/").pop();
    } catch {
      // The process went away, or is not ours to read.
    }
  }
  return undefined;
};

/**
 * Removes the worktree `at` sits in once nothing works there and worktrunk finds
 * no uncommitted work in it; worktrunk decides the branch, deleting one that
 * would add nothing to the default branch and keeping one that would. Undefined
 * when `at` is not a worktree of this repo, which is the primary checkout and the
 * common case.
 */
const closeWhenLeft = async (
  at: string,
  cwd: string,
  peers: readonly HubRow[],
  self: string | undefined,
): Promise<Notice | undefined> => {
  const worktree = (await worktrees(cwd).catch(() => [] as Worktree[])).find(
    (item) => !item.main && inside(at, item.path),
  );
  if (!worktree) return undefined;
  const who = whoIsWorking(worktree.path, peers, self);
  if (who) return { text: `Left ${worktree.path} open: ${who} works there`, warning: false };
  try {
    const removal = json<Removal[]>(
      await wt(["remove", worktree.path, "--foreground", "--format=json"], cwd),
    )?.[0];
    const kept = removal?.branch_outcome === "retained_unmerged" ? ", branch kept unmerged" : "";
    return { text: `Removed worktree ${worktree.branch}${kept}`, warning: false };
  } catch (error) {
    const said = (error as Error).message;
    if (DIRTY.test(said))
      return { text: `Left ${worktree.path} open: it has uncommitted changes`, warning: true };
    if (NOT_OURS.test(said)) return undefined;
    return { text: `Could not remove ${worktree.path}: ${said.split("\n")[0]}`, warning: true };
  }
};

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

export default function (pi: ExtensionAPI, services: Services) {
  // Worktree the agent asked to move to; set by the tool, consumed once the turn settles.
  let pending: { branch: string; path: string } | undefined;
  // The tool's move: `/wt` takes its path as it stands rather than switching again,
  // which would run the worktree's hooks twice for one creation.
  let agentMove: { branch: string; path: string } | undefined;
  // The hub's last listing, and this session in it.
  let peers: readonly HubRow[] = [];
  let self: string | undefined;

  const remember = () => {
    peers = services.hub.rows();
    self = services.hub.read()?.id ?? self;
  };
  remember();
  services.hub.onRows(remember);

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
        const left = await closeWhenLeft(from, path, peers, self);
        if (left) next.ui.notify(left.text, left.warning ? "warning" : "info");
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
    if (!ctx.hasUI || isLeanModel(ctx.model) || pi.getActiveTools().includes(ENTER_WORKTREE))
      return;
    pi.setActiveTools([...pi.getActiveTools(), ENTER_WORKTREE]);
  });

  // Quitting inside a worktree closes it; reload, /new, /resume and /fork keep the process going.
  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason === "quit") await closeWhenLeft(ctx.cwd, ctx.cwd, peers, self);
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
        `Worktree move cancelled; ${target.branch} was kept. Run /wt ${target.branch} to move later.`,
        "info",
      );
      return;
    }
    agentMove = target;
    // Deferred by pi until agent_settled finishes, then dispatched as a command.
    pi.sendUserMessage(`/wt ${target.branch}`, { expandPromptTemplates: true });
  });

  pi.registerCommand("wt", {
    description:
      "Move this session into a git worktree, creating it if needed: /wt <branch> [base]. Without a branch it picks an existing worktree.",
    getArgumentCompletions: async (prefix) =>
      (await names(process.cwd()))
        .filter((branch) => branch.startsWith(prefix))
        .map((branch) => ({ value: branch, label: branch })),
    handler: async (args, ctx) => {
      const moved = agentMove;
      agentMove = undefined;
      let [target = "", base] = args.trim().split(/\s+/);
      if (!target) {
        const existing = await names(ctx.cwd);
        if (existing.length === 0) {
          ctx.ui.notify("No worktrees yet; /wt <branch> creates one.", "info");
          return;
        }
        const picked = await ctx.ui.select("Worktree", existing);
        if (!picked) return;
        target = picked;
      }

      await ctx.waitForIdle();
      // The tool's move already made the worktree; switching again would run its hooks twice.
      let path = moved?.branch === target ? moved.path : undefined;
      if (!path) {
        try {
          const entered = await switchTo(target, ctx.cwd, base);
          path = entered.path;
          if (entered.copyFailed)
            ctx.ui.notify(`Could not copy the ignored files: ${entered.copyFailed}`, "warning");
        } catch (error) {
          ctx.ui.notify(`Could not enter worktree: ${(error as Error).message}`, "error");
          return;
        }
      }
      await moveTo(path, ctx, moved?.branch === target);
    },
  });

  pi.registerCommand("back", {
    description:
      "Move this session back to the repo's primary checkout, removing the worktree it leaves.",
    handler: async (_args, ctx) => {
      await ctx.waitForIdle();
      let path: string;
      try {
        path = await primaryPath(ctx.cwd);
      } catch (error) {
        ctx.ui.notify(`Not in a repo wt knows: ${(error as Error).message}`, "error");
        return;
      }
      await moveTo(path, ctx, false);
    },
  });

  pi.registerTool({
    name: ENTER_WORKTREE,
    label: "Enter worktree",
    description:
      "Create a git worktree (or pick an existing one) and move this session into it, keeping the conversation. " +
      "A new worktree starts from `base`, by default the default branch, so uncommitted changes in the current checkout don't come along; " +
      "the gitignored files the primary checkout's .worktreeinclude lists are copied into it. " +
      "Calling it ends your turn; the session then continues in the worktree on its own.",
    promptSnippet: "Move this session into a git worktree of its own",
    promptGuidelines: [
      "Use enter_worktree when the user asks for a worktree, or for more than a quick edit while a peer session works in this checkout (make a quick one in place and tell that peer). Otherwise edit the checkout you are in.",
      "Move with enter_worktree (`wt list` shows existing worktrees), not `wt switch` in bash, which leaves this session where it is.",
    ],
    parameters: Type.Object({
      name: Type.String({
        description:
          "Short kebab-case name for the branch and worktree directory, or the branch of an existing worktree",
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
      const switched = await switchTo(params.name, ctx.cwd, params.base);
      if (switched.path === ctx.cwd) throw new Error(`Already working in ${switched.path}`);
      pending = { branch: switched.branch, path: switched.path };
      return {
        content: [
          {
            type: "text",
            text:
              `Worktree ready at ${switched.path}. This session moves there when this turn ends; stop now and you will be prompted to continue.` +
              (switched.copyFailed
                ? ` Copying the gitignored files failed: ${switched.copyFailed}`
                : ""),
          },
        ],
        details: { path: switched.path },
        terminate: true,
      };
    },
  });
}
