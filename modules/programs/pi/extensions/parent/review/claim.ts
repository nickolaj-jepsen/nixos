/**
 * One review per repository: the claim file, taking it over, and the wait reason
 * the agent hub shows while a review is live (U8, U9, D7, D10).
 *
 * A claim is C2's record of which session owns this repository's review, in the
 * shape `lib/prompt-store.ts` writes its files: one JSON file per repository,
 * read-modify-write, a pid-suffixed temp renamed onto it. It is judged live by
 * what survives a crash — the process and the agent-hub's session registry —
 * never by `at`: the Claude side keeps its delivered watermark there (D7, C2).
 *
 * `foreignClaim` and `reviewLive` are what the opener asks and tells: who else
 * holds this repository, and that the hub should say a review is running. The
 * label has to be pushed before the TUI is suspended, because the review then
 * blocks pi's event loop (notes/s1-suspend.md).
 */
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import { type RegistryEntry, procStart, registryDirs } from "../claude-peers/protocol.ts";
import { readEntry } from "./entry.ts";
import type { ReviewEnv } from "./env.ts";
import { type Claim, type PinnedScope, type ReviewEntry, claimPath } from "./types.ts";

/** The key the review's wait reason is held under, so anything else can coexist. */
const WAIT_KEY = "review";

/** What a caller offers to write: C2's record minus the parts this file owns (root, pid, at). */
export type Claimant = {
  session: string;
  harness: Claim["harness"];
  slug: string | null;
  scope: PinnedScope;
  seen: string[];
};

/** A claim attempt: ours once written, or the live one that kept us out (U8). */
export type Claimed = { claim: Claim; held: Claim | undefined };

/**
 * pi's agent directory, which C2 keys the claim by. Resolved without pi's
 * `getAgentDir` so the review modules load outside pi, where the contract tests
 * read them: pi's wrapper and the Claude side resolve the same pair to find
 * this one file.
 */
const agentDir = () => process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

const plain = (path: string) => path.replace(/\/+$/, "") || "/";

/** The main checkout of `cwd`: one repository, one claim, however many worktrees (C2). */
export const repoRoot = (cwd: string): string => {
  const { root, main } = gitRoots(cwd);
  return plain(real(main ?? root ?? cwd));
};

const MODES = new Set<PinnedScope["mode"]>([
  "worktree",
  "commits",
  "picker",
  "all",
  "pr",
  "revset",
]);

const optionalText = (value: unknown) => value === undefined || typeof value === "string";

const asScope = (value: unknown): PinnedScope => {
  const scope = typeof value === "object" && value !== null ? (value as Partial<PinnedScope>) : {};
  if (!MODES.has(scope.mode as PinnedScope["mode"])) return { mode: "picker", args: [] };
  const args = Array.isArray(scope.args)
    ? scope.args.filter((arg): arg is string => typeof arg === "string")
    : [];
  return {
    mode: scope.mode as PinnedScope["mode"],
    args,
    ...(optionalText(scope.base) && scope.base !== undefined ? { base: scope.base } : {}),
    ...(optionalText(scope.head) && scope.head !== undefined ? { head: scope.head } : {}),
    ...(optionalText(scope.target) && scope.target !== undefined ? { target: scope.target } : {}),
  };
};

/**
 * A claim read off disk is a file another process may have written, possibly
 * years ago or by another version: only the fields that identify it are
 * trusted for liveness, and everything else is filled in.
 */
const asClaim = (value: unknown): Claim | undefined => {
  if (typeof value !== "object" || value === null) return undefined;
  const claim = value as Partial<Claim>;
  if (claim.v !== 1) return undefined;
  if (typeof claim.root !== "string" || typeof claim.session !== "string") return undefined;
  if (claim.harness !== "pi" && claim.harness !== "claude") return undefined;
  if (typeof claim.pid !== "number" || !Number.isInteger(claim.pid) || claim.pid <= 0)
    return undefined;
  return {
    v: 1,
    root: claim.root,
    session: claim.session,
    harness: claim.harness,
    pid: claim.pid,
    slug: typeof claim.slug === "string" ? claim.slug : null,
    scope: asScope(claim.scope),
    seen: Array.isArray(claim.seen)
      ? claim.seen.filter((id): id is string => typeof id === "string")
      : [],
    at: typeof claim.at === "string" ? claim.at : "",
  };
};

/** The claim `root` holds, or undefined when the file is missing or unreadable. */
export const readClaim = (root: string): Claim | undefined => {
  try {
    return asClaim(JSON.parse(readFileSync(claimPath(agentDir(), root), "utf8")));
  } catch {
    return undefined;
  }
};

/** C2's write: a pid-suffixed temp beside the claim, then a rename onto it. */
export const writeClaim = (claim: Claim): void => {
  const path = claimPath(agentDir(), claim.root);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(claim, null, 2)}\n`);
  renameSync(tmp, path);
};

/** Frees the repository, but only from this session's claim: another's is not ours to drop. */
export const releaseClaim = (root: string, session: string): void => {
  const existing = readClaim(root);
  if (existing === undefined) return;
  if (existing.session !== session || existing.harness !== "pi") return;
  try {
    unlinkSync(claimPath(agentDir(), root));
  } catch {
    // Already gone: nothing to release.
  }
};

const running = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
};

const alive = (entry: RegistryEntry): boolean => {
  if (!running(entry.pid)) return false;
  if (entry.procStart === undefined) return true;
  return procStart(entry.pid) === entry.procStart;
};

/**
 * Whether the agent-hub's registry still lists `session`: an interactive entry
 * whose process still runs. The hub reads the same registries (`registry.py`),
 * so a session that quit or crashed is gone here too, without asking the hub.
 */
export const listed = (session: string): boolean => {
  for (const dir of registryDirs()) {
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      if (!/^\d+\.json$/.test(name)) continue;
      let entry: RegistryEntry;
      try {
        entry = JSON.parse(readFileSync(join(dir, name), "utf8")) as RegistryEntry;
      } catch {
        continue;
      }
      if (entry?.sessionId !== session) continue;
      if (entry.kind !== undefined && entry.kind !== "interactive") continue;
      if (entry.entrypoint === "sdk-cli") continue;
      if (alive(entry)) return true;
    }
  }
  return false;
};

/**
 * A claim is stale when nothing about it survives: its process is gone, or the
 * session is no longer one the hub lists (D7). `at` says nothing about this.
 */
export const stale = (claim: Claim): boolean => !running(claim.pid) || !listed(claim.session);

const ours = (claim: Claim, owner: Claimant) =>
  claim.harness === owner.harness && claim.session === owner.session;

const merged = (existing: Claim | undefined, owner: Claimant): string[] =>
  // The file remembers what this repository has already delivered, whoever read
  // it: a takeover must not hand the same comments out twice (U8).
  existing === undefined
    ? [...new Set(owner.seen)]
    : [...new Set([...existing.seen, ...owner.seen])];

const record = (root: string, owner: Claimant, existing: Claim | undefined): Claim => ({
  v: 1,
  root,
  session: owner.session,
  harness: owner.harness,
  pid: process.pid,
  slug: owner.slug,
  scope: owner.scope,
  seen: merged(existing, owner),
  at: new Date().toISOString(),
});

/**
 * Writes this session's claim on `root` unless a live claim by another session
 * holds it (U8): the return says which claim the repository has now, and
 * `held` which one kept this session out. Read-modify-write, so a refresh by
 * the same session keeps the ids it already recorded.
 */
export const claim = (root: string, owner: Claimant): Claimed => {
  const existing = readClaim(root);
  if (existing !== undefined && !ours(existing, owner) && !stale(existing)) {
    return { claim: existing, held: existing };
  }
  const next = record(root, owner, existing);
  writeClaim(next);
  return { claim: next, held: undefined };
};

/**
 * Rewrites the claim whoever holds it, which is `/review take`'s deliberate act
 * (U8). The takeover keeps the ids the previous claim recorded, so a harness
 * that already drafted comments does not draft them again.
 */
export const takeOver = (root: string, owner: Claimant): Claim => {
  const next = record(root, owner, readClaim(root));
  writeClaim(next);
  return next;
};

/** A claim as the owner reads it in a notification: short enough for one line. */
export const describeClaim = (claim: Claim) =>
  `${claim.harness === "claude" ? "Claude " : ""}session ${claim.session.slice(0, 8)} (pid ${claim.pid})`;

const sessionOf = (ctx: ExtensionContext | undefined): string | undefined => {
  try {
    return ctx?.sessionManager.getSessionId();
  } catch {
    return undefined;
  }
};

const mine = (existing: Claim | undefined, ctx: ExtensionContext): boolean => {
  if (existing === undefined) return false;
  return existing.harness === "pi" && existing.session === sessionOf(ctx);
};

/** The live claim another session holds on this repository, if any (U8). */
export const foreignClaim = (env: ReviewEnv, ctx: ExtensionContext): string | undefined => {
  const existing = readClaim(repoRoot(ctx.cwd));
  if (existing === undefined || mine(existing, ctx) || stale(existing)) return undefined;
  return describeClaim(existing);
};

/** `/review take`: rewrite the claim as this session's, and say whose it was (D11). */
export const takeClaim = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  const root = repoRoot(ctx.cwd);
  const session = sessionOf(ctx);
  if (session === undefined) return;
  const existing = readClaim(root);
  const held =
    existing !== undefined && !mine(existing, ctx) && !stale(existing) ? existing : undefined;
  // The review this session already knows about, so a takeover keeps its pinned
  // scope, its slug and the ids it has ingested (C1, C2).
  const before = readEntry(env, ctx);
  takeOver(root, {
    session,
    harness: "pi",
    slug: before?.slug ?? existing?.slug ?? null,
    scope: before?.scope ?? existing?.scope ?? { mode: "picker", args: [] },
    seen: before?.seen ?? [],
  });
  if (held !== undefined) {
    ctx.ui.notify(
      `review: claimed by ${describeClaim(held)}; took over, /review attaches it`,
      "info",
    );
    return;
  }
  ctx.ui.notify("review: you hold the claim", "info");
};

/**
 * D10's text: how many comments are in the inbox and how far the reviewer has
 * got through the files. The file half is dropped when the listing has no file
 * count to show.
 */
export const waitText = (entry: ReviewEntry): string => {
  const comments = entry.items.length;
  const commentsText = `${comments} comment${comments === 1 ? "" : "s"}`;
  const { reviewedCount, fileCount } = entry.progress;
  if (fileCount <= 0) return `reviewing · ${commentsText}`;
  return `reviewing · ${commentsText}, ${reviewedCount}/${fileCount} files`;
};

/** What this session's review told the hub, per extension load. */
type Live = { root?: string; label?: string };

const live = new WeakMap<ReviewEnv, Live>();

const liveOf = (env: ReviewEnv): Live => {
  let entry = live.get(env);
  if (entry === undefined) live.set(env, (entry = {}));
  return entry;
};

/**
 * The review started, resumed or ended: the hub says so from now on, and the
 * repository's claim follows this session. Called with the entry before the
 * TUI is suspended and again once the review is up, then with `undefined` when
 * it ends. Nothing here waits on tuicr: the label has to be on the hub's socket
 * before `spawnSync` holds the event loop for the whole review.
 */
export const reviewLive = (env: ReviewEnv, entry: ReviewEntry | undefined): void => {
  const state = liveOf(env);
  if (entry === undefined) {
    state.label = undefined;
    env.dialogs?.hold(WAIT_KEY, undefined);
    const session = sessionOf(env.state?.ctx);
    if (state.root !== undefined && session !== undefined) releaseClaim(state.root, session);
    state.root = undefined;
    return;
  }
  state.root = entry.root;
  state.label = waitText(entry);
  env.dialogs?.hold(WAIT_KEY, state.label);
  const session = sessionOf(env.state?.ctx);
  if (session === undefined) return;
  claim(entry.root, {
    session,
    harness: "pi",
    slug: entry.slug,
    scope: entry.scope,
    seen: entry.seen,
  });
};

/** D10's text while a review is live; undefined otherwise. */
export const reviewWaitLabel = (env: ReviewEnv): string | undefined => liveOf(env).label;
