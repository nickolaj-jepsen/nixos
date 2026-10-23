/**
 * Git branch, status and pull request for the footer, refreshed off the render
 * path: `git status --porcelain=v2` runs asynchronously, so rendering never
 * waits on a subprocess, and it is asked again on a timer as well as after
 * pi's own events because other sessions share the checkout. A pull request for
 * the branch replaces its name with a
 * linked `#123`: the local gh-stack index answers synchronously, the GitHub API
 * refines the state in the background, and the last answer is cached on disk so
 * a fresh session paints before the network does.
 */
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import { getCapabilities, hyperlink } from "@earendil-works/pi-tui";
import type { BranchMode } from "./footer-line.ts";
import type { Part } from "./layout.ts";
import type { ChromeState } from "./state.ts";

type GitPaths = { gitDir: string; commonDir: string };

type PrKind = "open" | "draft" | "merged" | "closed";

/** `state` is missing when only the local gh-stack index knew the pull request. */
type PrRef = { number: number; url: string; state?: PrKind };

type PrCacheEntry = { pr: PrRef | null; fetchedAt: number };

type GitState = {
  branch: string | null;
  detached: boolean;
  oid: string;
  upstream: boolean;
  worktree: boolean;
  staged: number;
  unstaged: number;
  untracked: number;
  conflicts: number;
  ahead: number;
  behind: number;
  operation: string | undefined;
};

// Each lookup is a ~0.5s GitHub round trip for a value that moves a few times a
// day, so a cached answer is good enough until the branch or a gh command moves.
const PR_TTL_MS = 60_000;
const PR_RETRY_MS = 20_000;
const PR_TIMEOUT_MS = 5000;
const PR_CACHE_KEEP_MS = 30 * 24 * 60 * 60 * 1000;
const PR_CACHE_FILE = join(
  process.env.XDG_CACHE_HOME || join(homedir(), ".cache"),
  "pi",
  "pr-cache.json",
);
// Commands that can change which pull request a branch carries.
export const PR_COMMAND = /\bgh\s+pr\s+(create|merge|close|reopen|edit|ready)\b/;
// Pi emits events only for its own work, so a peer session, a subagent in this
// checkout or an external formatter changes the tree silently. `git status` costs
// milliseconds on a normal repo, and the busy guard keeps a slow one from stacking.
const POLL_MS = 2000;
const BRANCH_GLYPH = "\uf418";
const DETACHED_GLYPH = "\uf417";
const WORKTREE_GLYPH = "\uf1bb";
const PR_GLYPHS: Record<PrKind, string> = {
  open: "\uf407",
  draft: "\uf4dd",
  merged: "\uf419",
  closed: "\uf4dc",
};

const readTrim = (path: string) => {
  try {
    return readFileSync(path, "utf8").trim();
  } catch {
    return "";
  }
};

const detectOperation = (gitDir: string): string | undefined => {
  const rebaseMerge = join(gitDir, "rebase-merge");
  if (existsSync(rebaseMerge)) {
    const step = readStep(join(rebaseMerge, "msgnum"), join(rebaseMerge, "end"));
    return step ? `rebase ${step}` : "rebase";
  }
  const rebaseApply = join(gitDir, "rebase-apply");
  if (existsSync(rebaseApply)) {
    const op = existsSync(join(rebaseApply, "applying")) ? "am" : "rebase";
    const step = readStep(join(rebaseApply, "next"), join(rebaseApply, "last"));
    return step ? `${op} ${step}` : op;
  }
  if (existsSync(join(gitDir, "MERGE_HEAD"))) return "merge";
  if (existsSync(join(gitDir, "CHERRY_PICK_HEAD"))) return "cherry-pick";
  if (existsSync(join(gitDir, "REVERT_HEAD"))) return "revert";
  const next = readTrim(join(gitDir, "sequencer", "todo"))
    .split("\n")
    .find((line) => {
      const trimmed = line.trim();
      return trimmed !== "" && !trimmed.startsWith("#");
    });
  if (next?.startsWith("pick ") || next?.startsWith("p ")) return "cherry-pick";
  if (next?.startsWith("revert ")) return "revert";
  return undefined;
};

const readStep = (numFile: string, endFile: string) => {
  const num = readTrim(numFile);
  const end = readTrim(endFile);
  return num && end ? `${num}/${end}` : undefined;
};

/** Git branch, status and pull request for the footer, refreshed off the render path. */
export const createGit = (chrome: ChromeState) => {
  let gitState: GitState | null | undefined;
  let gitPathsCache: { cwd: string; value: GitPaths | null } | undefined;
  let gitBusy = false;
  let gitQueued = false;
  let gitTimer: ReturnType<typeof setTimeout> | undefined;
  let pollTimer: ReturnType<typeof setTimeout> | undefined;
  let polling = false;
  let activeCwd = "";

  let currentPr: PrRef | null = null;
  let prRequestKey = "";
  let prDirty = false;
  let prCache: Record<string, PrCacheEntry> | undefined;
  let ghMissing = false;
  // Failures are not cached: a lookup that never reached GitHub says nothing
  // about the branch, so it only backs off for a moment.
  const prRetryAt = new Map<string, number>();
  const prInFlight = new Set<string>();

  const runGit = (cwd: string, args: string[]) =>
    new Promise<string | null>((resolve) => {
      execFile(
        "git",
        ["--no-optional-locks", "-C", cwd, ...args],
        { timeout: 3000, maxBuffer: 1 << 20 },
        (error, stdout) => resolve(error ? null : stdout),
      );
    });

  const loadPrCache = (): Record<string, PrCacheEntry> => {
    if (prCache) return prCache;
    try {
      const parsed: unknown = JSON.parse(readFileSync(PR_CACHE_FILE, "utf8"));
      prCache =
        parsed && typeof parsed === "object" && !Array.isArray(parsed)
          ? (parsed as Record<string, PrCacheEntry>)
          : {};
    } catch {
      prCache = {};
    }
    return prCache;
  };

  const savePrCache = () => {
    const cache = loadPrCache();
    const cutoff = Date.now() - PR_CACHE_KEEP_MS;
    for (const [key, entry] of Object.entries(cache)) {
      if (!(entry?.fetchedAt > cutoff)) delete cache[key];
    }
    void mkdir(dirname(PR_CACHE_FILE), { recursive: true })
      .then(() => writeFile(PR_CACHE_FILE, `${JSON.stringify(cache)}\n`))
      .catch(() => {});
  };

  // gh-stack records the pull request each stacked branch carries, so this is
  // the one answer that needs neither a subprocess nor the network. It is a
  // cache of its own: an entry outlives the merge until the next `gh stack sync`.
  const readStackPr = (paths: GitPaths, branch: string): PrRef | null => {
    const dirs =
      paths.gitDir === paths.commonDir ? [paths.commonDir] : [paths.commonDir, paths.gitDir];
    for (const dir of dirs) {
      try {
        const data: unknown = JSON.parse(readFileSync(join(dir, "gh-stack"), "utf8"));
        const stacks = (data as { stacks?: unknown })?.stacks;
        if (!Array.isArray(stacks)) continue;
        for (const stack of stacks) {
          const branches = (stack as { branches?: unknown })?.branches;
          if (!Array.isArray(branches)) continue;
          for (const entry of branches) {
            const { branch: name, pullRequest } = (entry ?? {}) as {
              branch?: unknown;
              pullRequest?: { number?: unknown; url?: unknown };
            };
            if (name !== branch) continue;
            if (typeof pullRequest?.number === "number" && typeof pullRequest.url === "string") {
              return { number: pullRequest.number, url: pullRequest.url };
            }
          }
        }
      } catch {}
    }
    return null;
  };

  /** Resolve a branch's pull request from the cached answer, the local index, or both. */
  const resolvePr = (key: string, stack: PrRef | null): PrRef | null => {
    const entry = loadPrCache()[key];
    // A fresh API answer is authority, including "no pull request".
    if (entry && Date.now() - entry.fetchedAt < PR_TTL_MS) return entry.pr;
    return stack ?? entry?.pr ?? null;
  };

  const fetchPr = (cwd: string) =>
    new Promise<{ pr: PrRef | null } | null>((resolve) => {
      execFile(
        "gh",
        ["pr", "view", "--json", "number,url,state,isDraft"],
        { cwd, timeout: PR_TIMEOUT_MS, maxBuffer: 1 << 16 },
        (error, stdout, stderr) => {
          if (error) {
            // Without gh there is nothing to learn from retrying this session.
            if (error.code === "ENOENT") ghMissing = true;
            // These two are answers; anything else (offline, auth, timeout) is not.
            const none = /no pull requests found|no git remotes found/.test(stderr);
            resolve(none ? { pr: null } : null);
            return;
          }
          try {
            const data = JSON.parse(stdout) as {
              number: number;
              url: string;
              state: string;
              isDraft?: boolean;
            };
            const state: PrKind = data.isDraft
              ? "draft"
              : data.state === "MERGED"
                ? "merged"
                : data.state === "CLOSED"
                  ? "closed"
                  : "open";
            resolve({ pr: { number: data.number, url: data.url, state } });
          } catch {
            resolve(null);
          }
        },
      );
    });

  const setPr = (pr: PrRef | null) => {
    if (currentPr?.number === pr?.number && currentPr?.state === pr?.state) return;
    currentPr = pr;
    chrome.tui?.requestRender();
  };

  const refreshPr = async (state: GitState, paths: GitPaths, force: boolean) => {
    if (!state.branch) {
      prRequestKey = "";
      setPr(null);
      return;
    }
    const key = `${paths.commonDir}\0${state.branch}`;
    prRequestKey = key;
    const stack = readStackPr(paths, state.branch);
    const cache = loadPrCache();
    setPr(resolvePr(key, stack));
    if (ghMissing) return;

    // A branch that was never pushed has no pull request yet; one already known
    // stays visible after its remote branch is deleted on merge.
    if (!cache[key] && !state.upstream && !stack) return;
    const now = Date.now();
    if (!force && now - (cache[key]?.fetchedAt ?? 0) < PR_TTL_MS) return;
    if (!force && now < (prRetryAt.get(key) ?? 0)) return;
    if (prInFlight.has(key)) return;

    prInFlight.add(key);
    const result = await fetchPr(activeCwd);
    prInFlight.delete(key);
    if (result) {
      cache[key] = { pr: result.pr, fetchedAt: Date.now() };
      savePrCache();
      prRetryAt.delete(key);
    } else {
      prRetryAt.set(key, Date.now() + PR_RETRY_MS);
    }
    // The cache keeps the answer either way; only the painted line can be stale.
    if (prRequestKey !== key) return;
    setPr(resolvePr(key, stack));
  };

  const resolveGitPaths = async (cwd: string): Promise<GitPaths | null> => {
    if (gitPathsCache?.cwd === cwd) return gitPathsCache.value;
    const output = await runGit(cwd, [
      "rev-parse",
      "--path-format=absolute",
      "--git-dir",
      "--git-common-dir",
    ]);
    const [gitDir, commonDir] = output?.split("\n").filter(Boolean) ?? [];
    const value = gitDir && commonDir ? { gitDir, commonDir } : null;
    gitPathsCache = { cwd, value };
    return value;
  };

  const parseStatus = (output: string, paths: GitPaths): GitState => {
    let branch: string | null = null;
    let detached = false;
    let oid = "";
    let upstream = false;
    let ahead = 0;
    let behind = 0;
    let staged = 0;
    let unstaged = 0;
    let untracked = 0;
    let conflicts = 0;

    for (const line of output.split("\n")) {
      if (line.startsWith("# branch.head ")) {
        const head = line.slice("# branch.head ".length);
        if (head === "(detached)") detached = true;
        else branch = head;
      } else if (line.startsWith("# branch.oid ")) {
        oid = line.slice("# branch.oid ".length);
      } else if (line.startsWith("# branch.upstream ")) {
        upstream = true;
      } else if (line.startsWith("# branch.ab ")) {
        const match = /\+(\d+) -(\d+)/.exec(line);
        if (match) {
          ahead = Number(match[1]);
          behind = Number(match[2]);
        }
      } else if (line.startsWith("? ")) {
        untracked++;
      } else if (line.startsWith("u ")) {
        conflicts++;
      } else if (line.startsWith("1 ") || line.startsWith("2 ")) {
        const xy = line.slice(2, 4);
        if (xy[0] !== ".") staged++;
        if (xy[1] !== ".") unstaged++;
      }
    }

    return {
      branch,
      detached,
      oid,
      upstream,
      worktree: paths.gitDir !== paths.commonDir,
      staged,
      unstaged,
      untracked,
      conflicts,
      ahead,
      behind,
      operation: detectOperation(paths.gitDir),
    };
  };

  /** Serialized state, so a poll that learned nothing new does not repaint the TUI. */
  const stateKey = (state: GitState | null | undefined) => (state ? JSON.stringify(state) : "");

  const refreshGit = async () => {
    if (gitBusy) {
      gitQueued = true;
      return;
    }
    gitBusy = true;
    const cwd = activeCwd;
    try {
      const paths = await resolveGitPaths(cwd);
      if (!paths) {
        const changed = gitState !== null;
        gitState = null;
        prDirty = false;
        prRequestKey = "";
        setPr(null);
        if (changed) chrome.tui?.requestRender();
        return;
      }
      const status = await runGit(cwd, ["status", "--porcelain=v2", "--branch"]);
      if (!status) return;
      const previous = gitState;
      const next = parseStatus(status, paths);
      const changed = stateKey(previous) !== stateKey(next);
      gitState = next;
      // A branch switch or a first push changes which pull request the branch
      // carries; everything else waits for the cached answer to expire.
      const force =
        prDirty ||
        !previous ||
        previous.branch !== gitState.branch ||
        (!previous.upstream && gitState.upstream);
      prDirty = false;
      void refreshPr(gitState, paths, force);
      if (changed) chrome.tui?.requestRender();
    } finally {
      gitBusy = false;
      if (gitQueued) {
        gitQueued = false;
        scheduleGit(50);
      }
    }
  };

  const scheduleGit = (delay = 400) => {
    if (gitTimer) clearTimeout(gitTimer);
    gitTimer = setTimeout(() => {
      gitTimer = undefined;
      void refreshGit().catch(() => {});
    }, delay);
  };

  // One poll at a time: the next one is armed when the previous refresh settles,
  // so a slow status cannot queue up behind itself.
  const armPoll = () => {
    if (!polling || pollTimer) return;
    pollTimer = setTimeout(() => {
      pollTimer = undefined;
      void refreshGit()
        .catch(() => {})
        .finally(armPoll);
    }, POLL_MS);
    pollTimer.unref?.();
  };

  const prColor = (pr: PrRef): ThemeColor =>
    pr.state === "draft"
      ? "muted"
      : pr.state === "merged"
        ? "success"
        : pr.state === "closed"
          ? "error"
          : "accent";

  const branchView = (
    state: GitState | null | undefined,
    pr: PrRef | null,
    mode: BranchMode,
  ): Part | null => {
    // No fallback branch: `getGitBranch()` would show a bare name until the
    // async status lands, then move the line when the status arrives.
    if (mode === "none" || !state) return null;

    const name = state.detached ? state.oid.slice(0, 7) : (state.branch ?? "");
    const glyph = state.detached ? DETACHED_GLYPH : BRANCH_GLYPH;
    const stateColor: ThemeColor = state.operation
      ? "accent"
      : state.unstaged > 0 || state.conflicts > 0
        ? "error"
        : state.staged > 0
          ? "warning"
          : "success";
    const dirtyColor: ThemeColor | undefined =
      state.unstaged > 0 ? "error" : state.staged > 0 ? "warning" : undefined;

    const spans: { text: string; color: ThemeColor; attached?: boolean; url?: string }[] = [];
    if (state.worktree) spans.push({ text: WORKTREE_GLYPH, color: "muted" });
    spans.push({ text: glyph, color: stateColor });
    if (mode === "full" && name) spans.push({ text: name, color: "muted" });
    if (dirtyColor) spans.push({ text: "*", color: dirtyColor, attached: true });
    // The icon alone says a pull request exists; it links to it where the terminal can.
    if (pr) spans.push({ text: PR_GLYPHS[pr.state ?? "open"], color: prColor(pr), url: pr.url });
    if (state.operation) spans.push({ text: state.operation, color: "accent" });
    if (state.untracked > 0) spans.push({ text: "?", color: "warning" });
    if (state.conflicts > 0) spans.push({ text: `~${state.conflicts}`, color: "error" });
    if (state.ahead > 0 || state.behind > 0) {
      spans.push({
        text: `${state.ahead > 0 ? `⇡${state.ahead}` : ""}${state.behind > 0 ? `⇣${state.behind}` : ""}`,
        color: "muted",
      });
    }

    const plain = (withColor: boolean, theme?: Theme) =>
      spans
        .map((span, index) => {
          const space = index > 0 && !span.attached ? " " : "";
          const colored = withColor && theme ? theme.fg(span.color, span.text) : span.text;
          // Only painted lines link, so the width computed from `text` stays true.
          const body =
            withColor && span.url && getCapabilities().hyperlinks
              ? hyperlink(colored, span.url)
              : colored;
          return space + body;
        })
        .join("");

    return {
      id: "branch",
      text: plain(false),
      color: stateColor,
      styled: (theme) => plain(true, theme),
    };
  };

  return {
    view: (mode: BranchMode): Part | null => branchView(gitState, currentPr, mode),
    schedule: scheduleGit,
    /** Keep asking while the footer is on screen; stops on `dispose`. */
    startPolling: () => {
      polling = true;
      armPoll();
    },
    markPrDirty: () => {
      prDirty = true;
    },
    /** Points this at the session's cwd, which never changes, and asks git once. */
    start: (cwd: string) => {
      activeCwd = cwd;
      scheduleGit(0);
    },
    dispose: () => {
      polling = false;
      if (gitTimer) clearTimeout(gitTimer);
      if (pollTimer) clearTimeout(pollTimer);
      pollTimer = undefined;
    },
  };
};
