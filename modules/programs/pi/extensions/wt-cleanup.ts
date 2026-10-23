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
 * The dialog never guesses. "Land it" appears only when `wt apply` would accept
 * the worktree, a dirty one offers to commit first, and a main checkout that
 * cannot take a land gets no land button at all rather than a promise the script
 * then breaks.
 */
import { execFile } from "node:child_process";
import { readdirSync, readFileSync, readlinkSync, realpathSync } from "node:fs";
import { basename, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { NAME_MAX_TOKENS, NAME_MODEL, namingModel } from "./lib/naming.ts";
import { recordSideCall } from "./lib/usage-ledger.ts";
import { status, wt, type RepoStatus, type Worktree } from "./lib/wt.ts";

/** A window that is already closing does not get to hold the process for long. */
const ASK_MS = 5_000;
const COMMIT_MS = 5_000;
const DIFF_CHARS = 4_000;

const LAND = "Land it (wt apply)";
const REMOVE = "Remove it anyway";
const KEEP = "Keep it";
const COMMIT_KEEP = "Commit and keep";
const COMMIT_LAND = "Commit and land";
const KEEP_DIRTY = "Keep as is";

const MESSAGE_SYSTEM = `You write the commit message for a worktree that is being parked at the end of a coding session.
Reply with one line, imperative, at most 72 characters. No quotes, no trailing period, no "wip" unless nothing else fits.
Match the style of the commits the diff suggests, and say what the change does.`;

const git = (args: string[], cwd: string, maxBuffer = 8 * 1024 * 1024) =>
  new Promise<string>((resolve, reject) =>
    execFile("git", args, { cwd, encoding: "utf8", maxBuffer }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout),
    ),
  );

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
};

/**
 * Whether `cwd` is a linked worktree rather than the repo's main checkout. One
 * git call, so an exit from the main checkout (the common case) costs nothing
 * beyond it.
 */
const linkedWorktree = async (cwd: string) => {
  try {
    const [dir, common] = (
      await git(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], cwd)
    )
      .split("\n")
      .filter(Boolean);
    return dir !== undefined && common !== undefined && real(dir) !== real(common);
  } catch {
    return false; // not a git checkout
  }
};

/** Whether `cwd` is the worktree itself or somewhere inside it. */
const contains = (worktree: string, cwd: string) => {
  const root = real(worktree);
  const here = real(cwd);
  return here === root || here.startsWith(`${root}/`);
};

/**
 * Whether another process is living in the worktree. Cheaper and broader than a
 * registry of agent sessions: it also catches editors and shells, and erring
 * towards "in use" only means the worktree is kept.
 *
 * pi's own ancestors are not users: the shell that launched this session sits in
 * the worktree by construction and is about to lose its cwd with it, exactly as
 * it would after `wt clean`.
 */
const inUse = (worktree: string) => {
  const root = real(worktree);
  const ours = ancestors();
  let entries: string[];
  try {
    entries = readdirSync("/proc");
  } catch {
    return true; // no /proc (darwin): cannot tell, so keep the worktree
  }
  for (const entry of entries) {
    const pid = Number(entry);
    if (!/^\d+$/.test(entry) || ours.has(pid)) continue;
    let cwd: string;
    try {
      cwd = readlinkSync(`/proc/${entry}/cwd`);
    } catch {
      continue; // gone, or another user's process
    }
    if (cwd === root || cwd.startsWith(`${root}/`)) return true;
  }
  return false;
};

/** This process and everything that spawned it, up to init. */
const ancestors = () => {
  const pids = new Set<number>([process.pid]);
  let pid = process.pid;
  for (let hops = 0; hops < 64; hops++) {
    let stat: string;
    try {
      stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    } catch {
      break;
    }
    // `comm` can hold spaces and parens, so ppid is read after the last one.
    const ppid = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
    if (!Number.isFinite(ppid) || ppid <= 1 || pids.has(ppid)) break;
    pids.add(ppid);
    pid = ppid;
  }
  return pids;
};

/**
 * Whether `wt apply` would accept this worktree — by its own refusals — with the
 * commits it has, or, for a dirty one, with the commit it is about to get.
 */
const landable = (tree: Worktree, repo: RepoStatus, committing: boolean) =>
  tree.registered &&
  !tree.isMain &&
  !tree.locked &&
  tree.branch !== "" &&
  tree.branch !== repo.defaultBranch &&
  (committing || (tree.ahead ?? 0) > 0) &&
  repo.mainState === "clean" &&
  repo.mainBranch === repo.defaultBranch;

/** Why `wt apply` would refuse, when it would; undefined when the land could happen. */
const landBlocker = (tree: Worktree, repo: RepoStatus) => {
  if (tree.locked) return `${tree.name} is locked`;
  if (repo.mainState !== "clean") return `main has ${repo.mainState} files`;
  if (repo.mainBranch !== repo.defaultBranch)
    return `main is on ${repo.mainBranch || "a detached HEAD"}, not ${repo.defaultBranch}`;
  return undefined;
};

/** A one-line commit message for the staged diff, falling back to the session name. */
const writeMessage = async (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  tree: Worktree,
): Promise<string> => {
  const fallback = `wip: ${pi.getSessionName() ?? basename(tree.path)}`;
  const model = namingModel(ctx, process.env.PI_WT_COMMIT_MODEL || NAME_MODEL);
  if (!model) return fallback;
  const [stat, diff] = await Promise.all([
    git(["diff", "--cached", "--stat"], tree.path),
    git(["diff", "--cached"], tree.path),
  ]);
  const prompt = [
    `worktree: ${tree.name} (branch ${tree.branch})`,
    `files:`,
    stat.trim().slice(0, 1_000),
    "diff:",
    diff.slice(0, DIFF_CHARS),
  ].join("\n");
  try {
    const response = await ctx.modelRegistry
      .streamSimple(
        model,
        {
          systemPrompt: MESSAGE_SYSTEM,
          messages: [
            { role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() },
          ],
        },
        {
          maxTokens: NAME_MAX_TOKENS,
          temperature: 0,
          timeoutMs: COMMIT_MS,
          sessionId: ctx.sessionManager.getSessionId(),
        },
      )
      .result();
    recordSideCall(pi, "worktree commit", response);
    if (response.stopReason === "error" || response.stopReason === "aborted") return fallback;
    const reply = response.content
      .flatMap((block) => (block.type === "text" ? [block.text] : []))
      .join(" ")
      .replace(/\s+/g, " ")
      .replace(/^["'`]+|["'`.]+$/g, "")
      .trim();
    return reply === "" ? fallback : reply.slice(0, 72);
  } catch {
    return fallback;
  }
};

const report = (ctx: ExtensionContext, message: string, type: "info" | "error") => {
  try {
    ctx.ui.notify(message, type);
  } catch {
    // The terminal is gone; the worktree state is the record that matters.
  }
};

export default function (pi: ExtensionAPI) {
  /** Stages everything (`.gitignore` still filters) and commits it, if there is anything to commit. */
  const commit = async (ctx: ExtensionContext, tree: Worktree) => {
    try {
      await git(["add", "-A"], tree.path);
      if ((await git(["status", "--porcelain"], tree.path)).trim() === "") return false;
      const message = await writeMessage(pi, ctx, tree);
      await git(["commit", "-m", message], tree.path);
      report(ctx, `Committed ${tree.name}: ${message}`, "info");
      return true;
    } catch (error) {
      report(ctx, `Could not commit ${tree.name}: ${(error as Error).message}`, "error");
      return false;
    }
  };

  /** Runs a `wt` verb that ends in the worktree's removal, and says where it went wrong. */
  const dispose = async (ctx: ExtensionContext, tree: Worktree, verb: string[]) => {
    try {
      await wt(verb, ctx.cwd);
      report(ctx, `${verb[0] === "apply" ? "Landed" : "Removed"} ${tree.name}`, "info");
    } catch (error) {
      report(ctx, `Kept ${tree.name}: ${(error as Error).message}`, "error");
    }
  };

  pi.on("session_shutdown", async (event, ctx) => {
    // A move, fork, resume, new session or reload also shuts the old session
    // down. Those are not exits — `/wt` in particular is moving *into* a worktree.
    if (event.reason !== "quit" || ctx.mode !== "tui") return;
    if (!(await linkedWorktree(ctx.cwd))) return;

    let repo: RepoStatus;
    try {
      repo = await status(ctx.cwd);
    } catch {
      return; // not inside a git worktree of a repo `wt` knows
    }
    const tree = repo.worktrees.find((candidate) => contains(candidate.path, ctx.cwd));
    if (!tree || !tree.registered || tree.isMain) return;
    // A worktree parked on the default branch is a deliberate second checkout.
    if (tree.branch === repo.defaultBranch) return;
    if (inUse(tree.path)) return;

    // Nothing to decide when nothing can be lost, so nothing is asked.
    if (tree.safeToRemove) return void (await dispose(ctx, tree, ["clean", tree.name]));
    // Every other exit has no TUI left to draw in; keep the worktree.
    if (process.stdin.isRaw !== true) return;

    const dirty = tree.state !== "clean";
    const canLand = landable(tree, repo, dirty);
    const blocker = canLand ? undefined : landBlocker(tree, repo);
    // A missing button is a promise not made; say what stands in the way instead.
    if (blocker) report(ctx, `No land: ${blocker}`, "info");
    // With nothing to land, keep leads: a stray Enter on a closing window must
    // not be what drops commits.
    const options = dirty
      ? [COMMIT_KEEP, ...(canLand ? [COMMIT_LAND] : []), KEEP_DIRTY]
      : canLand
        ? [LAND, REMOVE, KEEP]
        : [KEEP, REMOVE];
    const ahead = tree.ahead === undefined ? "" : ` · ${tree.ahead} ahead`;
    const picked = await ctx.ui.select(`Worktree ${tree.name} · ${tree.state}${ahead}`, options, {
      signal: AbortSignal.timeout(ASK_MS),
    });

    if (picked === LAND) return void (await dispose(ctx, tree, ["apply", tree.name]));
    if (picked === REMOVE) return void (await dispose(ctx, tree, ["clean", "--force", tree.name]));
    if (picked !== COMMIT_KEEP && picked !== COMMIT_LAND) return; // keep, timeout, or aborted
    if (!(await commit(ctx, tree))) return;
    if (picked === COMMIT_LAND) await dispose(ctx, tree, ["apply", tree.name]);
  });
}
