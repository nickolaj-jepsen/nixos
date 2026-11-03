/**
 * The review's process life: hand the terminal to tuicr, hop back, hop in
 * again, and save-then-kill it when the review ends (U1, U7, D8, D12).
 *
 * The review is not pi's child. `dtach -A <socket>` runs tuicr behind a pty of
 * its own, and every hop is one client attaching to that pty, so the marks the
 * owner made stay in the still-running process while pi's TUI is gone
 * (notes/s1-suspend.md). One client at a time: dtach does not refuse a second
 * one, and the second one resets the pty to its own size
 * (notes/tuicr-dtach.md §5).
 *
 * Marks only reach disk through a save from inside the TUI, so ending a review
 * means asking it to save through the socket and then signalling its pid, never
 * the other way round (D8, M1).
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import { foreignClaim, reviewLive } from "./claim.ts";
import { readEntry, recordEntry } from "./entry.ts";
import type { ReviewEnv } from "./env.ts";
import { cliTuicr, ingestReview } from "./ingest.ts";
import {
  type PinnedScope,
  type ReviewEntry,
  type ReviewProgress,
  socketPath,
  tuicrArgv,
} from "./types.ts";

/** tuicr writes its pid file seconds after launch, and its slug line goes to the pty (M2). */
const REGISTER_BUDGET_MS = 5_000;
const POLL_MS = 250;
/** A blind `:w` reached the session file 30–400 ms after the injection in dtach's pty. */
const SAVE_BUDGET_MS = 1_000;
const SAVE_POLL_MS = 25;
const SAVE_SETTLE_MS = 100;
/** tuicr's own staleness rule for a pid file entry (notes/tuicr-dtach.md §4). */
const STALE_MS = 12 * 60 * 60 * 1_000;
/** SIGTERM ends tuicr at once, and its dtach daemon removes the socket within a second. */
const KILL_BUDGET_MS = 3_000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

/** tuicr records its checkout with a trailing slash; compare the path, not the spelling. */
const plain = (path: string) => path.replace(/\/+$/, "");

const runtimeDir = () => process.env.XDG_RUNTIME_DIR || tmpdir();
const dataHome = () => process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
const reviewsDir = () => join(dataHome(), "tuicr", "reviews");
const sessionDir = () => join(reviewsDir(), "sessions");

const isRunning = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // A process of another user exists but is not ours to signal.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
};

/** One tuicr the pid file lists: its process, the session it holds, and when it was last seen. */
export type LiveReview = { pid: number; slug: string; path: string; at: number };

/**
 * `active_sessions.json` as tuples of what the review needs. The file belongs to
 * tuicr and this is a read of it, so every field is checked before use: a
 * shape this does not recognise is skipped, not thrown over.
 */
export const parseActiveSessions = (text: string): LiveReview[] => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (typeof parsed !== "object" || parsed === null) return [];
  const sessions = (parsed as { sessions?: unknown }).sessions;
  if (!Array.isArray(sessions)) return [];
  const reviews: LiveReview[] = [];
  for (const raw of sessions) {
    if (typeof raw !== "object" || raw === null) continue;
    const { pid, slug, path, last_seen_at: seen } = raw as Record<string, unknown>;
    if (typeof pid !== "number" || !Number.isInteger(pid)) continue;
    if (typeof slug !== "string" || slug === "") continue;
    if (typeof path !== "string" || path === "") continue;
    const at = typeof seen === "string" ? Date.parse(seen) : Number.NaN;
    reviews.push({ pid, slug, path, at: Number.isNaN(at) ? 0 : at });
  }
  return reviews;
};

const activeSessions = (data: string): LiveReview[] => {
  try {
    return parseActiveSessions(
      readFileSync(join(data, "tuicr", "reviews", "active_sessions.json"), "utf8"),
    );
  } catch {
    return [];
  }
};

/** The checkout a session file names, which is the one tuicr was launched in. */
const sessionRoot = (path: string): string | undefined => {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (typeof parsed !== "object" || parsed === null) return undefined;
    const repo = (parsed as { repo_path?: unknown }).repo_path;
    return typeof repo === "string" && repo !== "" ? plain(real(repo)) : undefined;
  } catch {
    return undefined;
  }
};

export type LiveOptions = {
  /** The tuicr data home; defaults to `$XDG_DATA_HOME`. */
  data?: string;
  /** The checkouts the review may have been launched in; all of them when absent. */
  roots?: readonly string[];
  /** The clock, so a test can age an entry. */
  now?: number;
  /** The process table, so a test does not have to own pids. */
  running?: (pid: number) => boolean;
};

/**
 * The reviews that are running right now: fresh, `kill(pid, 0)`-alive, with the
 * session file they claim, newest first. `active: false` in `review list` does
 * not mean the review is worthless (it may be an orphan), but `active: true`
 * and this list agree — both are `is_fresh` over the same file.
 */
export const liveReviews = (options: LiveOptions = {}): LiveReview[] => {
  const now = options.now ?? Date.now();
  const running = options.running ?? isRunning;
  const roots =
    options.roots === undefined ? undefined : options.roots.map((root) => plain(real(root)));
  return activeSessions(options.data ?? dataHome())
    .filter(
      (review) => now - review.at <= STALE_MS && running(review.pid) && existsSync(review.path),
    )
    .filter((review) => {
      if (roots === undefined) return true;
      const root = sessionRoot(review.path);
      return root !== undefined && roots.includes(root);
    })
    .sort((a, b) => b.at - a.at);
};

/** `waitFor(read)` until it answers or the budget runs out. */
const waitFor = async <T>(read: () => T | undefined, budgetMs: number): Promise<T | undefined> => {
  const deadline = Date.now() + budgetMs;
  for (;;) {
    const value = read();
    if (value !== undefined) return value;
    if (Date.now() >= deadline) return undefined;
    await sleep(POLL_MS);
  }
};

/** The newest session file's mtime: `:w` rewrites it, so a change means the save landed. */
const newestSessionMtime = (): number | undefined => {
  let names: string[];
  try {
    names = readdirSync(sessionDir());
  } catch {
    return undefined;
  }
  let newest: number | undefined;
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      const at = statSync(join(sessionDir(), name)).mtimeMs;
      if (newest === undefined || at > newest) newest = at;
    } catch {
      // A session file another tuicr is rewriting is not a reason to fail.
    }
  }
  return newest;
};

/**
 * M2's fallback: the newest session file, named through the index tuicr keeps.
 * Only files written since the launch count, or a fresh review would adopt a
 * days-old session.
 */
const newestSlug = (sinceMs: number): string | undefined => {
  let names: string[];
  try {
    names = readdirSync(sessionDir());
  } catch {
    return undefined;
  }
  let newest: { name: string; at: number } | undefined;
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    let at: number;
    try {
      at = statSync(join(sessionDir(), name)).mtimeMs;
    } catch {
      continue;
    }
    if (at < sinceMs - 1_000) continue;
    if (newest === undefined || at > newest.at) newest = { name, at };
  }
  if (newest === undefined) return undefined;
  try {
    const parsed: unknown = JSON.parse(readFileSync(join(reviewsDir(), "index.json"), "utf8"));
    if (typeof parsed !== "object" || parsed === null) return undefined;
    const entries = (parsed as { entries?: unknown }).entries;
    if (typeof entries !== "object" || entries === null) return undefined;
    const wanted = join("sessions", newest.name);
    for (const [slug, versions] of Object.entries(entries as Record<string, unknown>)) {
      if (!Array.isArray(versions)) continue;
      for (const version of versions) {
        if (typeof version !== "object" || version === null) continue;
        const path = (version as { path?: unknown }).path;
        if (typeof path === "string" && plain(path).endsWith(wanted)) return slug;
      }
    }
  } catch {
    return undefined;
  }
  return undefined;
};

const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;

/** C1's `progress`, from the listing that names this session (notes/tuicr-dtach.md §1). */
const progressOf = async (
  roots: readonly string[],
  slug: string | null,
): Promise<ReviewProgress | undefined> => {
  if (slug === null) return undefined;
  for (const root of roots) {
    const result = await cliTuicr.list(root);
    if (result.code !== 0) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(result.stdout);
    } catch {
      continue;
    }
    if (!Array.isArray(parsed)) continue;
    for (const raw of parsed) {
      if (typeof raw !== "object" || raw === null) continue;
      const session = raw as Record<string, unknown>;
      if (session.slug !== slug) continue;
      return {
        reviewedCount: count(session.reviewed_count),
        fileCount: count(session.file_count),
      };
    }
  }
  return undefined;
};

/**
 * The review's main checkout, which is the socket's root (C6) and C1's `root`,
 * and every checkout its tuicr sessions can be listed under: the worktree pi
 * runs in first, then the main one (notes/tuicr-dtach.md §2).
 */
type Where = { main: string; list: string[] };

const rootsFor = (cwd: string): Where => {
  const { root, main } = gitRoots(cwd);
  const primary = plain(real(main ?? root ?? cwd));
  const worktree = plain(real(root ?? cwd));
  return { main: primary, list: worktree === primary ? [primary] : [worktree, primary] };
};

/**
 * The last resort when nothing pinned a scope: A1's picker answers that in the
 * terminal UI, so this only reaches tuicr from a caller that had no picker to
 * ask. An empty argv is tuicr's own commit and file picker.
 */
const UNPINNED: PinnedScope = { mode: "picker", args: [] };

/** M2: the slug of the review that just registered, polled because tuicr's own line goes to the pty. */
const registered = async (where: Where, sinceMs: number): Promise<string | undefined> => {
  const slug = await waitFor(() => liveReviews({ roots: where.list })[0]?.slug, REGISTER_BUDGET_MS);
  return slug ?? newestSlug(sinceMs);
};

/** The pid holding this repository's review: the pinned session's, else the only live one. */
const pidOf = (where: Where, slug: string | null): number | undefined => {
  const live = liveReviews({ roots: where.list });
  const pinned = slug === null ? undefined : live.find((review) => review.slug === slug);
  if (pinned !== undefined) return pinned.pid;
  return live.length === 1 ? live[0].pid : undefined;
};

/** One hop: where tuicr runs, the socket it lives behind, and its argv (C6). */
export type Hop = { cwd: string; socket: string; argv: string[] };

/**
 * dtach's command line for a hop (C6): `-A` so a stale socket is recovered
 * rather than refused, `-r winch` so tuicr repaints on attach, `^G` to come
 * back, then tuicr's own argv.
 */
export const dtachArgv = (spec: Hop): string[] => [
  "-A",
  spec.socket,
  "-r",
  "winch",
  "-e",
  "^G",
  "tuicr",
  ...spec.argv,
];

// One client at a time; a hop blocks pi's event loop anyway, so this only has to
// catch a second dispatch racing a reload.
let attaching = false;

const hop = async (ctx: ExtensionContext, spec: Hop): Promise<number | null> => {
  if (ctx.mode !== "tui" || !ctx.hasUI || attaching) return null;
  attaching = true;
  try {
    return await ctx.ui.custom<number | null>((tui, _theme, _keybindings, done) => {
      tui.stop();
      // tuicr draws a frame of its own; the clear keeps pi's last one out of it.
      process.stdout.write("\x1b[2J\x1b[H");
      const result = spawnSync("dtach", dtachArgv(spec), {
        cwd: spec.cwd,
        stdio: "inherit",
        env: process.env,
      });
      tui.start();
      tui.requestRender(true);
      // A missing dtach must not look like a review that opened and closed.
      if (result.error !== undefined)
        ctx.ui.notify(`review: could not run dtach (${result.error.message})`, "error");
      done(result.status ?? null);
      return { render: () => [], invalidate: () => {} };
    });
  } finally {
    attaching = false;
  }
};

/** Hand the terminal to a new review, `dtach -A` creating its socket (C6). */
export const start = (ctx: ExtensionContext, spec: Hop): Promise<number | null> => {
  mkdirSync(dirname(spec.socket), { recursive: true });
  return hop(ctx, spec);
};

/**
 * Attach the review that is already running: one this session left, one another
 * session runs, or one a crash left behind (D12). `-A` recovers from a socket
 * whose daemon is gone; `-a` would fail on it.
 */
export const attach = (ctx: ExtensionContext, spec: Hop): Promise<number | null> => hop(ctx, spec);

/** A review is there to attach while dtach's socket exists (C6). */
export const alive = (socket: string): boolean => existsSync(socket);

/** What finishing a review needs from the world, so the order D8 asks for is testable. */
export type EndIo = {
  running(pid: number): boolean;
  save(socket: string): Promise<void>;
  terminate(pid: number, socket: string): Promise<void>;
};

/** D8's save: bytes into the pty with no client attached (notes/tuicr-dtach.md §5). */
const saveThrough = async (socket: string): Promise<void> => {
  const before = newestSessionMtime();
  spawnSync("dtach", ["-p", socket], { input: ":w\r", timeout: 5_000 });
  const deadline = Date.now() + SAVE_BUDGET_MS;
  while (Date.now() < deadline) {
    const now = newestSessionMtime();
    if (now !== undefined && now !== before) break;
    if (!alive(socket)) break;
    await sleep(SAVE_POLL_MS);
  }
  await sleep(SAVE_SETTLE_MS);
};

const terminate = async (pid: number, socket: string): Promise<void> => {
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
  const deadline = Date.now() + KILL_BUDGET_MS;
  while (Date.now() < deadline && (isRunning(pid) || alive(socket))) await sleep(50);
  if (!isRunning(pid)) return;
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Gone between the check and the signal.
  }
};

const endIo: EndIo = { running: isRunning, save: saveThrough, terminate };

/**
 * D8/M1: ask the review to save, then SIGTERM its pid and wait for the socket to
 * go. Returns whether there was a review left to finish, so ending one twice is
 * a no-op rather than an error.
 */
export const finish = async (
  socket: string,
  pid: number | undefined,
  io: EndIo = endIo,
): Promise<boolean> => {
  const live = alive(socket);
  const target = pid !== undefined && io.running(pid) ? pid : undefined;
  if (!live && target === undefined) return false;
  if (live) await io.save(socket);
  if (target !== undefined) await io.terminate(target, socket);
  return true;
};

/** An ingest failure is a notification; it must not take the review's hop down. */
const collect = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  try {
    await ingestReview(env, ctx);
  } catch (error) {
    ctx.ui.notify(`review: ${error instanceof Error ? error.message : String(error)}`, "error");
  }
};

/** Open the pinned scope, or attach the review that is already running (D11, D12). */
export const openReview = async (
  env: ReviewEnv,
  ctx: ExtensionContext,
  scope: PinnedScope | undefined,
): Promise<void> => {
  if (ctx.mode !== "tui" || !ctx.hasUI) return;
  const where = rootsFor(ctx.cwd);
  const socket = socketPath(runtimeDir(), where.main);
  const before = readEntry(env, ctx);
  const claim = foreignClaim(env, ctx);
  if (claim !== undefined && !alive(socket)) {
    ctx.ui.notify(`review: claimed by ${claim}; /review take takes it over`, "info");
    return;
  }
  const pinned = scope ?? before?.scope ?? UNPINNED;
  // The hub has to hear about this before the TUI stops: spawnSync then holds
  // pi's event loop until the owner detaches (notes/s1-suspend.md).
  reviewLive(env, before);
  const live = alive(socket);
  if (!live) ctx.ui.notify("review: ^G returns to pi; /review kill saves and closes", "info");
  const since = Date.now();
  const spec: Hop = { cwd: ctx.cwd, socket, argv: tuicrArgv(pinned) };
  await (live ? attach(ctx, spec) : start(ctx, spec));
  const slug = (await registered(where, since)) ?? before?.slug ?? null;
  const entry: ReviewEntry = {
    v: 1,
    root: where.main,
    cwd: ctx.cwd,
    harness: "pi",
    slug,
    scope: pinned,
    socket,
    items: before?.items ?? [],
    seen: before?.seen ?? [],
    sent: before?.sent ?? [],
    progress: (await progressOf(where.list, slug)) ??
      before?.progress ?? { reviewedCount: 0, fileCount: 0 },
    at: new Date().toISOString(),
  };
  recordEntry(env, ctx, entry);
  reviewLive(env, entry);
  await collect(env, ctx);
};

/** Save, then kill the running review (D8). Idempotent: nothing live is nothing to do. */
export const killReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  const where = rootsFor(ctx.cwd);
  const socket = socketPath(runtimeDir(), where.main);
  const before = readEntry(env, ctx);
  const ended = await finish(socket, pidOf(where, before?.slug ?? null));
  reviewLive(env, undefined);
  ctx.ui.notify(ended ? "review: saved and closed" : "review: nothing to close", "info");
  await collect(env, ctx);
};

/**
 * U7's teardown, on session end, extension reload and session replacement alike.
 * Another session's claim wins: a review dies with the session that owns it.
 */
export const shutdownReview = async (env: ReviewEnv): Promise<void> => {
  const ctx = env.state.ctx;
  if (ctx === undefined) return;
  if (foreignClaim(env, ctx) !== undefined) return;
  const where = rootsFor(ctx.cwd);
  const socket = socketPath(runtimeDir(), where.main);
  const before = readEntry(env, ctx);
  await finish(socket, pidOf(where, before?.slug ?? null));
};
