/**
 * What a session does with the worktree it is leaving, and the rules for doing it.
 *
 * Two callers ask: pi exiting (`wt-cleanup.ts`), where nothing may be asked
 * unless the terminal is provably alive, and `/back` (and `/new` from inside a
 * worktree), where the user is present and a worktree left behind is exactly
 * what they expect to be asked about.
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
import { NAME_MAX_TOKENS, NAME_MODEL, namingModel } from "./naming.ts";
import { recordSideCall } from "./usage-ledger.ts";
import { status, wt, type RepoStatus, type Worktree } from "./wt.ts";

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
 * git call, so asking from the main checkout (the common case) costs nothing
 * beyond it.
 */
export const linkedWorktree = async (cwd: string) => {
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

/** The linked worktree holding `path`, whether or not it may be removed. */
export const worktreeAt = (repo: RepoStatus, path: string) =>
  repo.worktrees.find((tree) => !tree.isMain && contains(tree.path, path));

/**
 * The same, when the session may offer to remove it: a worktree parked on the
 * default branch is a deliberate second checkout, not a leftover.
 */
export const removableAt = (repo: RepoStatus, path: string) => {
  const tree = worktreeAt(repo, path);
  return tree === undefined || !tree.registered || tree.branch === repo.defaultBranch
    ? undefined
    : tree;
};

/** `removableAt` for the session's own cwd, behind the git call that keeps it cheap. */
export const sessionWorktree = async (cwd: string) => {
  if (!(await linkedWorktree(cwd))) return undefined;
  let repo: RepoStatus;
  try {
    repo = await status(cwd);
  } catch {
    return undefined; // not inside a worktree of a repo `wt` knows
  }
  const tree = removableAt(repo, cwd);
  return tree === undefined ? undefined : { repo, tree };
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

/** What became of a parked worktree, in one line, and how loud to say it. */
export type ParkResult = { text: string; type: "info" | "error" };

export const report = (ctx: ExtensionContext, message: string, type: "info" | "error") => {
  try {
    ctx.ui.notify(message, type);
  } catch {
    // The terminal is gone; the worktree state is the record that matters.
  }
};

type Commit = { ok: true; message?: string } | { ok: false; error: string };

/** Stages everything (`.gitignore` still filters) and commits it, if there is anything to commit. */
const commit = async (pi: ExtensionAPI, ctx: ExtensionContext, tree: Worktree): Promise<Commit> => {
  try {
    await git(["add", "-A"], tree.path);
    if ((await git(["status", "--porcelain"], tree.path)).trim() === "") return { ok: true };
    const message = await writeMessage(pi, ctx, tree);
    await git(["commit", "-m", message], tree.path);
    return { ok: true, message };
  } catch (error) {
    return { ok: false, error: (error as Error).message };
  }
};

/** Runs a `wt` verb that ends in the worktree's removal, and says where it went wrong. */
const dispose = async (
  ctx: ExtensionContext,
  tree: Worktree,
  verb: string[],
): Promise<ParkResult> => {
  const said = verb[0] === "apply" ? "Landed" : "Removed";
  try {
    await wt(verb, ctx.cwd);
    return { text: `${said} ${tree.name}`, type: "info" };
  } catch (error) {
    return { text: `Kept ${tree.name}: ${(error as Error).message}`, type: "error" };
  }
};

export type ParkOptions = {
  /** Remove a worktree `wt clean` would accept without asking: nothing can be lost. */
  quietSafe?: boolean;
  /** Skip the dialog — there is no terminal left to draw it in. */
  noDialog?: boolean;
  /** Deadline for the dialog, for callers that cannot wait for an answer. */
  signal?: AbortSignal;
};

/**
 * Asks what should become of `tree` — land it, remove it, keep it, optionally
 * committing first — and does it, in a session that still belongs to the caller.
 * `repo` is the `wt status` that named `tree`.
 *
 * The answer comes back rather than being drawn on the spot: a caller that moves
 * the session afterwards has nothing left to draw in, and carries the line into
 * the session it lands in. `undefined` means nothing was asked or done.
 */
export const park = async (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  repo: RepoStatus,
  tree: Worktree,
  opts: ParkOptions = {},
): Promise<ParkResult | undefined> => {
  if (inUse(tree.path))
    return { text: `Kept ${tree.name}: another shell or editor is in it`, type: "info" };
  // Nothing to decide when nothing can be lost, so nothing is asked.
  if (opts.quietSafe && tree.safeToRemove) return dispose(ctx, tree, ["clean", tree.name]);
  // An exit that left no TUI behind has nowhere to ask: keep rather than guess.
  if (opts.noDialog) return undefined;

  const dirty = tree.state !== "clean";
  const canLand = landable(tree, repo, dirty);
  // Where commits could be dropped, keep leads: a stray Enter must not be what
  // drops them. A `wt clean`-safe worktree has nothing to drop, so removal leads.
  const choices = tree.safeToRemove
    ? [REMOVE, KEEP]
    : dirty
      ? [COMMIT_KEEP, ...(canLand ? [COMMIT_LAND] : []), KEEP_DIRTY]
      : canLand
        ? [LAND, REMOVE, KEEP]
        : [KEEP, REMOVE];
  // A missing button is a promise not made; the title says what stands in the way.
  const blocker = canLand || tree.safeToRemove ? undefined : landBlocker(tree, repo);
  const title = [
    `Worktree ${tree.name}`,
    tree.state,
    ...(tree.ahead ? [`${tree.ahead} ahead`] : []),
    ...(blocker ? [`no land: ${blocker}`] : []),
  ].join(" · ");
  const picked = await ctx.ui.select(title, choices, { signal: opts.signal });

  if (picked === LAND) return dispose(ctx, tree, ["apply", tree.name]);
  if (picked === REMOVE) return dispose(ctx, tree, ["clean", "--force", tree.name]);
  // Keep, timeout, or aborted: the worktree stays as it is.
  if (picked !== COMMIT_KEEP && picked !== COMMIT_LAND)
    return { text: `Kept ${tree.name}`, type: "info" };
  const committed = await commit(pi, ctx, tree);
  if (!committed.ok)
    return { text: `Could not commit ${tree.name}: ${committed.error}`, type: "error" };
  const note = committed.message
    ? `Committed ${tree.name}: ${committed.message}`
    : `Nothing to commit in ${tree.name}`;
  if (picked !== COMMIT_LAND) return { text: note, type: "info" };
  const landed = await dispose(ctx, tree, ["apply", tree.name]);
  return { text: `${note}; ${landed.text}`, type: landed.type };
};
