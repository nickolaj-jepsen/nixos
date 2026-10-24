/**
 * The `wt` CLI as the extensions see it: one exec wrapper and the porcelain
 * parser. The rules that matter — what may be removed, what may be landed —
 * stay in `wt` itself, so pi, the Claude Code hooks and the opencode plugin
 * cannot drift apart on the one decision that deletes work.
 */
import { execFile } from "node:child_process";

/** One worktree as `wt status` reports it. */
export type Worktree = {
  name: string;
  path: string;
  registered: boolean;
  branch: string;
  /** clean | dirty | untracked for a registered worktree, orphan for a dir git forgot. */
  state: string;
  /** Commits vs origin/<default>; undefined when there is no such ref to compare with. */
  ahead?: number;
  behind?: number;
  locked: boolean;
  ageSeconds: number;
  /** `wt clean` would remove it: clean, nothing unlanded ahead, unlocked, nobody else's cwd inside, not the main checkout. */
  safeToRemove: boolean;
  isMain: boolean;
};

export type RepoStatus = { worktrees: Worktree[]; defaultBranch: string };

/** The tool that moves a pi session into a worktree. */
export const ENTER_WORKTREE_TOOL = "enter_worktree";

/** `wt status` field order; see the usage text in wt.bash. */
const FIELDS = 12;

const num = (value: string | undefined) => {
  const parsed = Number(value);
  return value === undefined || value === "" || !Number.isFinite(parsed) ? undefined : parsed;
};

/** Runs `wt`, resolving its stdout; a non-zero exit rejects with what it said on stderr. */
export const wt = (args: string[], cwd: string, timeoutMs = 120_000) =>
  new Promise<string>((resolve, reject) =>
    execFile("wt", args, { cwd, encoding: "utf8", timeout: timeoutMs }, (error, stdout, stderr) =>
      error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout.trim()),
    ),
  );

/** Every worktree of the repo containing `cwd`, or the one named `name`. */
export const status = async (cwd: string, name?: string): Promise<RepoStatus> => {
  const out = await wt(name === undefined ? ["status"] : ["status", name], cwd);
  const worktrees: Worktree[] = [];
  let defaultBranch = "";
  for (const line of out.split("\n")) {
    if (line === "") continue;
    const field = line.split("\x1f");
    if (field.length !== FIELDS)
      throw new Error(`wt status: expected ${FIELDS} fields in "${line}"`);
    worktrees.push({
      name: field[0],
      path: field[1],
      registered: field[2] === "1",
      branch: field[3],
      state: field[4],
      ahead: num(field[5]),
      behind: num(field[6]),
      locked: field[7] === "1",
      ageSeconds: num(field[8]) ?? 0,
      safeToRemove: field[9] === "1",
      isMain: field[10] === "1",
    });
    defaultBranch = field[11];
  }
  if (worktrees.length === 0) throw new Error("wt status: no rows");
  return { worktrees, defaultBranch };
};

/** Every worktree name, for completion and as the set an automatic name must avoid. */
export const names = (cwd: string) =>
  wt(["names"], cwd).then(
    (out) => out.split("\n").filter(Boolean),
    () => [] as string[],
  );

/** Branch names `wt create` would refuse, so an automatic name has to avoid them too. */
export const branches = (cwd: string) =>
  new Promise<string[]>((resolve) =>
    execFile(
      "git",
      ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
      { cwd, encoding: "utf8" },
      (error, stdout) => resolve(error ? [] : stdout.split("\n").filter(Boolean)),
    ),
  );
