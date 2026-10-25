import { execFile } from "node:child_process";
import { basename } from "node:path";

export type GitContext = { repo: string; branch?: string };

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
