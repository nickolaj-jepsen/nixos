import { execFile, execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename, dirname } from "node:path";

export type GitContext = { repo: string; branch?: string };

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

const git = (cwd: string, args: string[]) => {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return undefined;
  }
};

/**
 * Worktree root and main checkout of `cwd`, both unset outside git. Every
 * worktree of a repository reports the same `main`, which is what a per-repo
 * file keys on.
 */
export const gitRoots = (cwd: string): { root?: string; main?: string } => {
  const out = git(cwd, [
    "rev-parse",
    "--path-format=absolute",
    "--show-toplevel",
    "--git-common-dir",
  ]);
  if (!out) return {};
  const [top, common] = out.split("\n");
  if (!top) return {};
  // A bare common dir has no main checkout; treat the worktree as its own main.
  const main = common && basename(common) === ".git" ? dirname(common) : top;
  return { root: real(top), main: real(main) };
};

// A branch moves a few times a day and every call would otherwise pay a subprocess.
const GIT_TTL_MS = 30_000;

/**
 * The repository and checked-out branch of a directory, or the directory name
 * outside git. Cached for a short while per instance, so each caller keeps its own.
 */
export const createGitContext = () => {
  let cache: { cwd: string; at: number; value: GitContext } | undefined;
  return async (cwd: string): Promise<GitContext> => {
    if (cache && cache.cwd === cwd && Date.now() - cache.at < GIT_TTL_MS) return cache.value;
    const stdout = await new Promise<string>((resolve) =>
      execFile(
        "git",
        ["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"],
        { cwd, timeout: 1000 },
        // Not a checkout, or git is missing: the directory still says which project this is.
        (error, out) => resolve(error ? "" : out),
      ),
    );
    const [top, head] = stdout.trim().split("\n");
    const value: GitContext = top
      ? { repo: basename(top), branch: head && head !== "HEAD" ? head : undefined }
      : { repo: basename(cwd) || cwd };
    cache = { cwd, at: Date.now(), value };
    return value;
  };
};
