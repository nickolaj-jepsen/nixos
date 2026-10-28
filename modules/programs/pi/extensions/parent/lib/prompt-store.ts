/**
 * What prompts leave behind in a repository: the history up-arrow browses, the
 * draft each session's editor held, and the stashed prompt. One JSON file per
 * repository, keyed by its main checkout so a worktree and the checkout it came
 * from share one.
 */
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";

/** Prompts kept for browsing; pi's editor holds no more than this. */
const HISTORY = 100;
/** Drafts kept per repository, so a month of sessions cannot grow the file. */
const DRAFTS = 10;

/** A prompt parked until something claims it, and when it was parked. */
export type Held = { text: string; at: string };

export type RepoPrompts = {
  /** The checkout the file is keyed by, so the file says what it belongs to. */
  root: string;
  /** Newest first, in the order the editor browses them. */
  history: string[];
  /** Session id → the draft that session's editor held. */
  drafts: Record<string, Held>;
  stash?: Held;
};

export const held = (text: string): Held => ({ text, at: new Date().toISOString() });

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

// A draft is written whenever typing pauses, so each session asks git about its
// directory's checkout once.
const files = new Map<string, { path: string; root: string }>();

const file = (cwd: string): { path: string; root: string } => {
  const known = files.get(cwd);
  if (known) return known;
  // Outside git the directory stands for itself, as it does for memory.
  const root = gitRoots(cwd).main ?? real(cwd);
  // A hash rather than a name: a checkout's path can outrun the filename limit.
  const key = createHash("sha256").update(root).digest("hex").slice(0, 16);
  const resolved = { path: join(getAgentDir(), "prompt-history", `${key}.json`), root };
  files.set(cwd, resolved);
  return resolved;
};

const isHeld = (value: unknown): value is Held =>
  typeof (value as Held | undefined)?.text === "string" &&
  typeof (value as Held | undefined)?.at === "string";

const draftsOf = (value: unknown): Record<string, Held> =>
  typeof value === "object" && value !== null
    ? Object.fromEntries(Object.entries(value).filter(([, draft]) => isHeld(draft)))
    : {};

/** The newest drafts, because their sessions are the ones a person returns to. */
const newest = (drafts: Record<string, Held>) =>
  Object.fromEntries(
    Object.entries(drafts)
      .sort(([, a], [, b]) => b.at.localeCompare(a.at))
      .slice(0, DRAFTS),
  );

export const readPrompts = (cwd: string): RepoPrompts => {
  const { path, root } = file(cwd);
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<RepoPrompts>;
    return {
      root,
      history: (parsed.history ?? []).filter((text): text is string => typeof text === "string"),
      drafts: draftsOf(parsed.drafts),
      ...(isHeld(parsed.stash) ? { stash: parsed.stash } : {}),
    };
  } catch {
    // Missing, unreadable or written by another version: history rebuilds itself
    // from what gets typed from here, so there is nothing to report.
    return { root, history: [], drafts: {} };
  }
};

/**
 * Re-reads the file, applies `change` and writes it back, so a second session
 * in the same repository merges rather than overwrites.
 */
export const updatePrompts = (cwd: string, change: (prompts: RepoPrompts) => void) => {
  const { path } = file(cwd);
  const prompts = readPrompts(cwd);
  change(prompts);
  prompts.history = prompts.history.slice(0, HISTORY);
  prompts.drafts = newest(prompts.drafts);
  try {
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(prompts, null, 2)}\n`);
    renameSync(tmp, path);
  } catch {
    // Typing must never fall over for want of a state file.
  }
};
