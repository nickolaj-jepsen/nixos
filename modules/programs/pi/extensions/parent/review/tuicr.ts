/**
 * The review's process life: hand the terminal to tuicr and read back what it
 * leaves (U1, U7).
 *
 * tuicr is pi's child for the length of one review. The TUI stops, tuicr owns
 * the terminal, and quitting it — `q` (`q_quits` is on), `:q` or `ZZ` — gives
 * the terminal back to pi. Nothing survives the hop: no socket to keep, no
 * orphan to adopt, no save-then-kill. tuicr writes its session as the review
 * goes, so the comments outlive the window on their own, and the next `/rv`
 * reopens the same scope under the same slug.
 */
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import { reviewLive } from "./live.ts";
import { readEntry, recordEntry } from "./entry.ts";
import type { ReviewEnv } from "./env.ts";
import { cliTuicr, ingestReview, listedSessions, type Listing } from "./ingest.ts";
import type { ReviewEntry, ReviewProgress } from "./types.ts";

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

/** tuicr records its checkout with a trailing slash; compare the path, not the spelling. */
const plain = (path: string) => path.replace(/\/+$/, "");

const NO_PROGRESS: ReviewProgress = { reviewedCount: 0, fileCount: 0 };

/** A session counts as this review's if tuicr touched it after the launch. */
const SINCE_SLACK_MS = 1_000;

/**
 * The review's main checkout (which the entry is keyed on), and
 * every checkout its tuicr sessions can be listed under: the worktree pi runs
 * in first, then the main one (notes/tuicr-dtach.md §2).
 */
type Where = { main: string; list: string[] };

const rootsFor = (cwd: string): Where => {
  const { root, main } = gitRoots(cwd);
  const primary = plain(real(main ?? root ?? cwd));
  const worktree = plain(real(root ?? cwd));
  return { main: primary, list: worktree === primary ? [primary] : [worktree, primary] };
};

const listedFor = async (where: Where): Promise<Listing[]> => {
  const all: Listing[] = [];
  for (const root of where.list) all.push(...listedSessions(root, await cliTuicr.list(root)));
  return all;
};

/**
 * The session this review just wrote: tuicr keeps the slug to itself on the
 * pty, so the newest session it touched since the launch is the one to read.
 * A review the owner backed out of without writing anything has none.
 */
export const latestSession = (listed: readonly Listing[], sinceMs: number): Listing | undefined =>
  listed
    .filter((session) => session.updated >= sinceMs - SINCE_SLACK_MS)
    .sort((a, b) => b.updated - a.updated)[0];

/** Where tuicr runs and the argv it is handed (C6). */
export type HandOver = { cwd: string; argv: string[] };

// A hop blocks pi's event loop, so this only has to catch a second dispatch
// racing a reload.
let handing = false;

/** Stop pi's TUI, let tuicr own the terminal until it quits, and take it back. */
const handOver = async (ctx: ExtensionContext, spec: HandOver): Promise<void> => {
  if (ctx.mode !== "tui" || !ctx.hasUI || handing) return;
  handing = true;
  try {
    await ctx.ui.custom<void>((tui, _theme, _keybindings, done) => {
      tui.stop();
      // tuicr draws a frame of its own; the clear keeps pi's last one out of it.
      process.stdout.write("\x1b[2J\x1b[H");
      const result = spawnSync("tuicr", spec.argv, {
        cwd: spec.cwd,
        stdio: "inherit",
        env: process.env,
      });
      tui.start();
      tui.requestRender(true);
      // A missing binary must not look like a review that opened and closed.
      if (result.error !== undefined)
        ctx.ui.notify(`review: could not run tuicr (${result.error.message})`, "error");
      done();
      return { render: () => [], invalidate: () => {} };
    });
  } finally {
    handing = false;
  }
};

/** An ingest failure is a notification; it must not take the review's hop down. */
const collect = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  try {
    await ingestReview(env, ctx);
  } catch (error) {
    ctx.ui.notify(`review: ${error instanceof Error ? error.message : String(error)}`, "error");
  }
};

/** Open tuicr on the argv, then record what it left behind (D11). */
export const openReview = async (
  env: ReviewEnv,
  ctx: ExtensionContext,
  args: readonly string[],
): Promise<void> => {
  if (ctx.mode !== "tui" || !ctx.hasUI) return;
  const where = rootsFor(ctx.cwd);
  const before = readEntry(env, ctx);
  // The hub has to hear about this before the TUI stops: spawnSync then holds
  // pi's event loop for as long as the review runs. On the first review of a
  // session there is no entry yet, so one describes what is opening.
  const opening: ReviewEntry = before ?? {
    v: 1,
    root: where.main,
    cwd: ctx.cwd,
    harness: "pi",
    slug: null,
    args: [...args],
    items: [],
    seen: [],
    sent: [],
    progress: NO_PROGRESS,
    at: new Date().toISOString(),
  };
  reviewLive(env, opening);
  ctx.ui.notify("review: quit tuicr (q, or :q) to come back here", "info");
  const since = Date.now();
  await handOver(ctx, { cwd: ctx.cwd, argv: [...args] });
  const found = latestSession(await listedFor(where), since);
  const entry: ReviewEntry = {
    v: 1,
    root: where.main,
    cwd: ctx.cwd,
    harness: "pi",
    slug: found?.slug ?? before?.slug ?? null,
    args: [...args],
    items: before?.items ?? [],
    seen: before?.seen ?? [],
    sent: before?.sent ?? [],
    progress: found?.progress ?? before?.progress ?? NO_PROGRESS,
    at: new Date().toISOString(),
  };
  recordEntry(env, ctx, entry);
  // The review is over: the hub stops saying this session is asking.
  reviewLive(env, undefined);
  await collect(env, ctx);
};

/** U7's teardown, on session end, extension reload and session replacement alike. */
export const shutdownReview = async (env: ReviewEnv): Promise<void> => {
  reviewLive(env, undefined);
};
