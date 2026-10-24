/**
 * What a session does with the worktree it is leaving. The dialog never guesses:
 * "Land it" appears only when `wt apply --dry-run` accepts the worktree, and a
 * dirty one is offered a commit instead, since `wt apply` refuses it.
 */
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { NAME_MAX_TOKENS } from "./naming.ts";
import { sideCall } from "./side-call.ts";
import { status, wt, type RepoStatus, type Worktree } from "./wt.ts";

const COMMIT_MS = 5_000;
const DIFF_CHARS = 4_000;

const LAND = "Land it (wt apply)";
const REMOVE = "Remove it anyway";
const KEEP = "Keep it";
const COMMIT_KEEP = "Commit and keep";
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

/** Why `wt apply` would refuse the worktree, or undefined when its dry run accepts it. */
const landBlocker = (ctx: ExtensionContext, tree: Worktree) =>
  wt(["apply", "--dry-run", tree.name], ctx.cwd).then(
    () => undefined,
    (error: Error) => error.message.replace(/^wt: /, ""),
  );

/** A one-line commit message for the staged diff, falling back to the session name. */
const writeMessage = async (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  tree: Worktree,
): Promise<string> => {
  const fallback = `wip: ${pi.getSessionName() ?? basename(tree.path)}`;
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
  const reply = await sideCall(pi, ctx, {
    source: "worktree commit",
    system: MESSAGE_SYSTEM,
    prompt,
    maxTokens: NAME_MAX_TOKENS,
    timeoutMs: COMMIT_MS,
  });
  if ("error" in reply) return fallback;
  const message = reply.text
    .replace(/\s+/g, " ")
    .replace(/^["'`]+|["'`.]+$/g, "")
    .trim();
  return message === "" ? fallback : message.slice(0, 72);
};

/** What became of a parked worktree, in one line, and how loud to say it. */
export type ParkResult = { text: string; type: "info" | "error" };

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

/**
 * Asks what should become of `tree` — land it, remove it, keep it, or commit and
 * keep a dirty one — and does it, in a session that still belongs to the caller.
 * `repo` is the `wt status` that named `tree`.
 *
 * The answer comes back rather than being drawn on the spot: a caller that moves
 * the session afterwards has nothing left to draw in, and carries the line into
 * the session it lands in.
 */
export const park = async (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  tree: Worktree,
): Promise<ParkResult> => {
  const dirty = tree.state !== "clean";
  const blocker =
    dirty || tree.safeToRemove || !tree.ahead ? undefined : await landBlocker(ctx, tree);
  const canLand = !dirty && !tree.safeToRemove && !!tree.ahead && blocker === undefined;
  // Where commits could be dropped, keep leads: a stray Enter must not be what
  // drops them. A `wt clean`-safe worktree has nothing to drop, so removal leads.
  const choices = tree.safeToRemove
    ? [REMOVE, KEEP]
    : dirty
      ? [COMMIT_KEEP, KEEP_DIRTY]
      : canLand
        ? [LAND, REMOVE, KEEP]
        : [KEEP, REMOVE];
  // A missing button is a promise not made; the title says what stands in the way.
  const title = [
    `Worktree ${tree.name}`,
    tree.state,
    ...(tree.ahead ? [`${tree.ahead} ahead`] : []),
    ...(blocker ? [`no land: ${blocker}`] : []),
  ].join(" · ");
  const picked = await ctx.ui.select(title, choices);

  if (picked === LAND) return dispose(ctx, tree, ["apply", tree.name]);
  if (picked === REMOVE) return dispose(ctx, tree, ["clean", "--force", tree.name]);
  // Keep, or dismissed: the worktree stays as it is.
  if (picked !== COMMIT_KEEP) return { text: `Kept ${tree.name}`, type: "info" };
  const committed = await commit(pi, ctx, tree);
  if (!committed.ok)
    return { text: `Could not commit ${tree.name}: ${committed.error}`, type: "error" };
  return {
    text: committed.message
      ? `Committed ${tree.name}: ${committed.message}`
      : `Nothing to commit in ${tree.name}`,
    type: "info",
  };
};
