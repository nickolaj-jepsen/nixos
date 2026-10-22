/**
 * One calm line under the editor: model and context first, diagnostics only
 * when they mean something, and the fish-style git segment on the right.
 *
 * Cost, cache health and speed come from session entries; the branch comes
 * from asynchronously refreshed `git status --porcelain=v2`, so rendering
 * never waits on a subprocess. A pull request for the branch replaces its name
 * with a linked `#123`: the local gh-stack index answers synchronously, the
 * GitHub API refines the state in the background, and the last answer is cached
 * on disk so a fresh session paints before the network does.
 */
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
  ReadonlyFooterDataProvider,
  Theme,
  ThemeColor,
} from "@earendil-works/pi-coding-agent";
import { getCapabilities, hyperlink, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

type ActiveModel = NonNullable<ExtensionContext["model"]>;
type Renderer = { requestRender(): void };

type Stats = {
  cost: number;
  cacheRead: number;
  cacheHit: number | undefined;
  speed: number | undefined;
};

type Part = {
  id: string;
  text: string;
  color: ThemeColor;
  styled?: (theme: Theme) => string;
};

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

const SEP = " · ";
const PAD = 2;
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
const PR_COMMAND = /\bgh\s+pr\s+(create|merge|close|reopen|edit|ready)\b/;
// A short reply is mostly time-to-first-token, and a small prompt makes a hit
// rate noisy. Only show diagnostics once the sample means something.
const MIN_SPEED_OUTPUT_TOKENS = 100;
const MIN_CACHE_PROMPT_TOKENS = 2000;
const BRANCH_GLYPH = "\uf418";
const DETACHED_GLYPH = "\uf417";
const WORKTREE_GLYPH = "\uf1bb";

// Long, well-known lab names only; Qwen, GLM, Kimi, Nemotron and LongCat keep
// their catalog names. Claude is redundant next to the provider tag.
const MODEL_ALIAS_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bDeepSeek\b/gi, "DS"],
  [/\bMiniMax\b/gi, "MM"],
  [/\bClaude\s+/gi, ""],
];

// Exceptions the patterns cannot express; add an entry when a model needs a
// name of its own.
const MODEL_ALIASES: Record<string, string> = {};

const modelAlias = (model: ActiveModel): string => {
  const explicit = MODEL_ALIASES[model.id];
  if (explicit) return explicit;
  let alias = model.name || model.id;
  for (const [pattern, replacement] of MODEL_ALIAS_PATTERNS) {
    alias = alias.replace(pattern, replacement);
  }
  return alias.replace(/\s+/g, " ").trim() || model.name || model.id;
};

// Short provider tags; unknown providers fall back to their full id.
const PROVIDER_TAGS: Record<string, string> = {
  opencode: "zen",
  "opencode-go": "go",
  tensorx: "tx",
  anthropic: "anth",
  local: "\uf015",
};

const sanitize = (text: string) =>
  text
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/ +/g, " ")
    .trim();

const formatTokens = (count: number) => {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) {
    const millions = count / 1000000;
    return `${Number.isInteger(millions) ? millions : millions.toFixed(1)}M`;
  }
  return `${Math.round(count / 1000000)}M`;
};

const formatCost = (cost: number) => {
  if (cost === 0) return "$0.00";
  if (cost < 0.01) return `$${cost.toFixed(3)}`;
  return `$${cost.toFixed(2)}`;
};

const addUsage = (
  totals: { cost: number; cacheRead: number },
  usage: { cacheRead: number; cost?: { total: number } } | undefined,
) => {
  if (!usage) return;
  totals.cost += usage.cost?.total ?? 0;
  totals.cacheRead += usage.cacheRead;
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

export default function (pi: ExtensionAPI) {
  let ctxRef: ExtensionContext | undefined;
  let tuiRef: Renderer | undefined;
  let statsCache:
    | { sessionId: string; leafId: string | null; modelKey: string; stats: Stats }
    | undefined;

  let gitState: GitState | null | undefined;
  let gitPathsCache: { cwd: string; value: GitPaths | null } | undefined;
  let gitBusy = false;
  let gitQueued = false;
  let gitTimer: ReturnType<typeof setTimeout> | undefined;
  let activeCwd = "";
  let generation = 0;

  let currentPr: PrRef | null = null;
  let prRequestKey = "";
  let prDirty = false;
  let prCache: Record<string, PrCacheEntry> | undefined;
  let ghMissing = false;
  // Failures are not cached: a lookup that never reached GitHub says nothing
  // about the branch, so it only backs off for a moment.
  const prRetryAt = new Map<string, number>();
  const prInFlight = new Set<string>();

  const collectStats = (ctx: ExtensionContext, model: ActiveModel | undefined): Stats => {
    const totals = { cost: 0, cacheRead: 0 };
    let cacheHit: number | undefined;
    let lastSpeed: { provider: string; model: string; value: number } | undefined;

    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "usage") {
        addUsage(totals, entry.usage);
      } else if (entry.type === "message") {
        const message = entry.message;
        if (message.role === "assistant") {
          addUsage(totals, message.usage);
          const prompt = message.usage.input + message.usage.cacheRead + message.usage.cacheWrite;
          if (prompt >= MIN_CACHE_PROMPT_TOKENS) {
            cacheHit = (message.usage.cacheRead / prompt) * 100;
          }
          if (
            message.usage.output >= MIN_SPEED_OUTPUT_TOKENS &&
            message.stopReason !== "error" &&
            message.stopReason !== "aborted"
          ) {
            const seconds = (Date.parse(entry.timestamp) - message.timestamp) / 1000;
            if (Number.isFinite(seconds) && seconds >= 0.5) {
              lastSpeed = {
                provider: message.provider,
                model: message.model,
                value: message.usage.output / seconds,
              };
            }
          }
        } else if (message.role === "toolResult") {
          addUsage(totals, message.usage);
          // Tools that bill their own API report it here, since no usage block carries it.
          const spent = (message.details as { costUsd?: unknown } | undefined)?.costUsd;
          if (typeof spent === "number") totals.cost += spent;
        }
      } else if ((entry.type === "compaction" || entry.type === "branch_summary") && entry.usage) {
        addUsage(totals, entry.usage);
      }
    }

    // A speed from another model would read as the current model's.
    const speed =
      model && lastSpeed?.provider === model.provider && lastSpeed.model === model.id
        ? lastSpeed.value
        : undefined;

    return { ...totals, cacheHit, speed };
  };

  const statsFor = (ctx: ExtensionContext, model: ActiveModel | undefined): Stats => {
    // Entries are append-only and every append moves the leaf, so leaf + model
    // is enough to know the scan is still current.
    const sessionId = ctx.sessionManager.getSessionId();
    const leafId = ctx.sessionManager.getLeafId();
    const modelKey = model ? `${model.provider}/${model.id}` : "";
    const cached = statsCache;
    if (
      cached &&
      cached.sessionId === sessionId &&
      cached.leafId === leafId &&
      cached.modelKey === modelKey
    ) {
      return cached.stats;
    }
    const stats = collectStats(ctx, model);
    statsCache = { sessionId, leafId, modelKey, stats };
    return stats;
  };

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
    tuiRef?.requestRender();
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

    const mine = generation;
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
    if (mine !== generation || prRequestKey !== key) return;
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

  const refreshGit = async () => {
    if (gitBusy) {
      gitQueued = true;
      return;
    }
    gitBusy = true;
    const mine = generation;
    const cwd = activeCwd;
    try {
      const paths = await resolveGitPaths(cwd);
      if (mine !== generation) return;
      if (!paths) {
        gitState = null;
        prDirty = false;
        prRequestKey = "";
        setPr(null);
        tuiRef?.requestRender();
        return;
      }
      const status = await runGit(cwd, ["status", "--porcelain=v2", "--branch"]);
      if (mine !== generation || !status) return;
      const previous = gitState;
      gitState = parseStatus(status, paths);
      // A branch switch or a first push changes which pull request the branch
      // carries; everything else waits for the cached answer to expire.
      const force =
        prDirty ||
        !previous ||
        previous.branch !== gitState.branch ||
        (!previous.upstream && gitState.upstream);
      prDirty = false;
      void refreshPr(gitState, paths, force);
      tuiRef?.requestRender();
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

  const track = (ctx: ExtensionContext) => {
    ctxRef = ctx;
    if (ctx.cwd === activeCwd) return;
    activeCwd = ctx.cwd;
    generation++;
    gitState = undefined;
    gitPathsCache = undefined;
    prRequestKey = "";
    currentPr = null;
    scheduleGit(0);
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
    mode: "full" | "glyph" | "none",
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
    // The `#` marks the pull request, so the branch glyph would be noise there,
    // and the number is already the short form narrow widths fall back to.
    if (pr) {
      spans.push({ text: `#${pr.number}`, color: prColor(pr), url: pr.url });
    } else {
      spans.push({ text: glyph, color: stateColor });
      if (mode === "full" && name) spans.push({ text: name, color: "muted" });
    }
    if (dirtyColor) spans.push({ text: "*", color: dirtyColor, attached: true });
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

  const renderLine = (
    width: number,
    theme: Theme,
    footerData: ReadonlyFooterDataProvider,
  ): string => {
    const ctx = ctxRef;
    if (!ctx || width <= PAD * 2) return "";
    const innerWidth = width - PAD * 2;

    const model = ctx.model;
    const stats = statsFor(ctx, model);
    const usage = ctx.getContextUsage();
    const thinking = ctx.thinkingLevel ?? pi.getThinkingLevel();

    const alias = model ? modelAlias(model) : "no model";
    const providerTag = model ? (PROVIDER_TAGS[model.provider] ?? model.provider) : "";
    const providerPart: Part | undefined = providerTag
      ? { id: "provider", text: providerTag, color: "muted" }
      : undefined;
    const aliasPart = (text = alias): Part => ({ id: "model", text, color: "muted" });

    const effortPart =
      model?.reasoning && thinking
        ? ({ id: "effort", text: thinking, color: "muted" } satisfies Part)
        : undefined;

    const percent = usage?.percent;
    const contextColor: ThemeColor =
      percent == null ? "dim" : percent >= 85 ? "error" : percent >= 60 ? "warning" : "dim";

    const contextPart = (showWindow: boolean): Part => {
      const percentText =
        percent == null ? "?" : `${Math.max(0, Math.min(100, Math.floor(percent)))}%`;
      const window = usage?.contextWindow ?? model?.contextWindow ?? 0;
      const windowText = showWindow && window > 0 ? ` / ${formatTokens(window)}` : "";
      return {
        id: "context",
        text: percentText + windowText,
        color: contextColor,
        styled:
          windowText && contextColor !== "dim"
            ? (t) => t.fg(contextColor, percentText) + t.fg("dim", windowText)
            : undefined,
      };
    };

    const paid = (model?.cost.input ?? 0) > 0 || (model?.cost.output ?? 0) > 0;
    const costText = stats.cost > 0 || paid ? formatCost(stats.cost) : undefined;
    const cacheHit = stats.cacheHit;
    const cacheText =
      stats.cacheRead > 0 && cacheHit !== undefined ? `CH${Math.round(cacheHit)}%` : undefined;
    const speedText =
      stats.speed !== undefined && Number.isFinite(stats.speed) && stats.speed > 0
        ? `${Math.round(stats.speed)} t/s`
        : undefined;

    const statuses = [...footerData.getExtensionStatuses()]
      .filter(([key]) => key !== "pi-cache-stats")
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([, text]) => sanitize(text))
      .filter(Boolean);

    const optional: Part[] = [];
    if (costText) optional.push({ id: "cost", text: costText, color: "dim" });
    if (cacheText && cacheHit !== undefined) {
      optional.push({
        id: "cache",
        text: cacheText,
        color: cacheHit < 50 ? "error" : cacheHit < 90 ? "warning" : "dim",
      });
    }
    if (speedText) optional.push({ id: "speed", text: speedText, color: "dim" });
    statuses.forEach((text, index) => {
      optional.push({ id: `status-${index}`, text, color: "dim" });
    });

    let showWindow = true;
    let branchMode: "full" | "glyph" | "none" = "full";

    const build = (aliasOverride?: string) => {
      const required: Part[] = [];
      if (providerPart) required.push(providerPart);
      required.push(aliasPart(aliasOverride));
      if (effortPart) required.push(effortPart);
      required.push(contextPart(showWindow));
      const left = [...required, ...optional];
      const leftWidth = visibleWidth(left.map((part) => part.text).join(SEP));
      const right = branchView(gitState, currentPr, branchMode);
      const rightWidth = right ? visibleWidth(right.text) : 0;
      return { left, leftWidth, right, rightWidth, gap: innerWidth - leftWidth - rightWidth };
    };

    const fits = () => {
      const layout = build();
      return layout.gap >= 2 || (layout.right === null && layout.leftWidth <= innerWidth);
    };

    if (!fits()) {
      // Yield order: statuses, speed, cost, cache, context window, branch, model.
      for (let i = optional.length - 1; i >= 0; i--) {
        if (optional[i].id.startsWith("status-")) {
          optional.splice(i, 1);
          if (fits()) break;
        }
      }
    }

    for (const id of ["speed", "cost", "cache"]) {
      if (fits()) break;
      const index = optional.findIndex((part) => part.id === id);
      if (index >= 0) optional.splice(index, 1);
    }

    if (!fits() && showWindow) {
      showWindow = false;
    }

    if (!fits() && branchMode === "full") {
      branchMode = "glyph";
    }

    if (!fits() && branchMode === "glyph") {
      branchMode = "none";
    }

    let modelOverride: string | undefined;
    if (!fits()) {
      const fixed = [
        ...(providerPart ? [providerPart.text] : []),
        ...(effortPart ? [effortPart.text] : []),
        contextPart(showWindow).text,
      ];
      const restWidth = visibleWidth(fixed.join(SEP)) + visibleWidth(SEP);
      const maxModelWidth = innerWidth - restWidth;
      if (maxModelWidth > 0) {
        // The provider is its own field and stays; only the alias truncates.
        modelOverride = truncateToWidth(alias, maxModelWidth, "…");
      }
    }

    const layout = build(modelOverride);
    const left = layout.left
      .map((part, index) => {
        const body = part.styled ? part.styled(theme) : theme.fg(part.color, part.text);
        return index === 0 ? body : theme.fg("dim", SEP) + body;
      })
      .join("");
    const right = layout.right
      ? layout.right.styled
        ? layout.right.styled(theme)
        : theme.fg(layout.right.color, layout.right.text)
      : undefined;
    const pad = " ".repeat(PAD);

    if (!right) return pad + truncateToWidth(left, innerWidth, "…");

    const gap = innerWidth - layout.leftWidth - layout.rightWidth;
    if (gap < 2) {
      return pad + truncateToWidth(left, innerWidth, "…");
    }
    return pad + left + " ".repeat(gap) + right + pad;
  };

  const mountFooter = (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    ctx.ui.setFooter((tui, theme, footerData) => {
      tuiRef = tui;
      const unsubscribe = footerData.onBranchChange(() => {
        scheduleGit(0);
        tui.requestRender();
      });
      scheduleGit(0);
      return {
        render: (width: number) => [renderLine(width, theme, footerData)],
        invalidate: () => {},
        dispose: () => {
          unsubscribe();
          if (gitTimer) clearTimeout(gitTimer);
          if (tuiRef === tui) tuiRef = undefined;
        },
      };
    });
  };

  pi.on("session_start", (_event, ctx) => {
    ctxRef = ctx;
    activeCwd = ctx.cwd;
    generation++;
    statsCache = undefined;
    gitState = undefined;
    gitPathsCache = undefined;
    prRequestKey = "";
    prDirty = false;
    currentPr = null;
    ghMissing = false;
    prRetryAt.clear();
    mountFooter(ctx);
    scheduleGit(0);
  });

  pi.on("model_select", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
  });

  pi.on("thinking_level_select", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
  });

  pi.on("message_end", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
  });

  pi.on("turn_end", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
    scheduleGit();
  });

  pi.on("agent_start", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
  });

  pi.on("agent_end", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
    scheduleGit();
  });

  // A pull request created or merged a moment ago should not wait out the TTL.
  pi.on("tool_execution_start", (event) => {
    const command = event.toolName === "bash" ? event.args?.command : undefined;
    if (typeof command === "string" && PR_COMMAND.test(command)) prDirty = true;
  });

  pi.on("tool_execution_end", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
    scheduleGit();
  });

  pi.on("user_bash", (event, ctx) => {
    if (PR_COMMAND.test(event.command)) prDirty = true;
    track(ctx);
    scheduleGit();
  });

  pi.on("session_compact", (_event, ctx) => {
    track(ctx);
    statsCache = undefined;
    tuiRef?.requestRender();
  });

  pi.on("session_tree", (_event, ctx) => {
    track(ctx);
    statsCache = undefined;
    tuiRef?.requestRender();
  });

  pi.on("session_info_changed", (_event, ctx) => {
    track(ctx);
    tuiRef?.requestRender();
  });
}
