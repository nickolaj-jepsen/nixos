/**
 * Reading tuicr's sessions back into the inbox: which sessions belong to this
 * repository and this pi session (D6), how far the reviewer has got (C1's
 * `progress`), and which comments have not been ingested yet (C4).
 *
 * Both reads go through `tuicr review list` and `tuicr review comments`. The
 * session files behind them belong to tuicr, and the CLI is the shape it
 * promises (notes/tuicr-dtach.md §1). A session it cannot resolve exits 1,
 * which is not an error here: it only means there is nothing to read.
 */
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import { readEntry, recordEntry } from "./entry.ts";
import type { ReviewEnv } from "./env.ts";
import {
  type InboxItem,
  type RawComment,
  type ReviewEntry,
  type ReviewProgress,
  inboxItem,
} from "./types.ts";

/** A large review's comment array is well under this; a runaway one is cut off, not read. */
const MAX_OUTPUT = 8 << 20;
/** A hung binary must not hold up an ingest. */
const CLI_TIMEOUT_MS = 5_000;

/** What one tuicr subprocess printed and how it exited. */
export type TuicrResult = { code: number; stdout: string };

/**
 * Ingest's two reads as one seam, so a test can answer from fixtures and the
 * wiring can answer from the binary. `root` is the checkout `--repo` names.
 */
export type TuicrSource = {
  list(root: string): Promise<TuicrResult>;
  comments(root: string, slug: string): Promise<TuicrResult>;
};

const runTuicr = (args: string[]): Promise<TuicrResult> =>
  new Promise((resolve) =>
    execFile(
      "tuicr",
      args,
      { encoding: "utf8", timeout: CLI_TIMEOUT_MS, maxBuffer: MAX_OUTPUT },
      (error, stdout) =>
        resolve({
          // A missing binary is not an exit code; both read as "nothing there".
          code: error === null ? 0 : typeof error.code === "number" ? error.code : 1,
          stdout: stdout ?? "",
        }),
    ),
  );

/** The installed binary. */
export const cliTuicr: TuicrSource = {
  list: (root) => runTuicr(["review", "list", "--repo", root]),
  comments: (root, slug) => runTuicr(["review", "comments", "--session", slug, "--repo", root]),
};

/** One `review list` element, of which ingest reads these fields (C1, C4). */
type RawSession = {
  slug?: unknown;
  updated_at?: unknown;
  comment_count?: unknown;
  reviewed_count?: unknown;
  file_count?: unknown;
  active?: unknown;
};

/** A session as `review list` reports it, with the checkout that listed it. */
export type Listing = {
  root: string;
  slug: string;
  active: boolean;
  comments: number;
  progress: ReviewProgress;
  /** `updated_at` in milliseconds: the order the M2 fallback picks from. */
  updated: number;
};

/** A session whose comments are worth reading, and the `--repo` that resolves its slug. */
type Candidate = { slug: string; root: string };

const real = (path: string) => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;

const listing = (root: string, raw: unknown): Listing | undefined => {
  if (typeof raw !== "object" || raw === null) return undefined;
  const session = raw as RawSession;
  if (typeof session.slug !== "string" || session.slug === "") return undefined;
  const updated =
    typeof session.updated_at === "string" ? Date.parse(session.updated_at) : Number.NaN;
  return {
    root,
    slug: session.slug,
    active: session.active === true,
    comments: count(session.comment_count),
    progress: {
      reviewedCount: count(session.reviewed_count),
      fileCount: count(session.file_count),
    },
    updated: Number.isNaN(updated) ? 0 : updated,
  };
};

/** `review list` prints a bare JSON array; anything else reads as "no sessions" (notes §1). */
export const listedSessions = (root: string, result: TuicrResult): Listing[] => {
  if (result.code !== 0) return [];
  try {
    const parsed: unknown = JSON.parse(result.stdout);
    return Array.isArray(parsed) ? parsed.flatMap((raw) => listing(root, raw) ?? []) : [];
  } catch {
    return [];
  }
};

/** `review comments` prints a bare JSON array; a session that is gone exits 1. */
const comments = (result: TuicrResult): RawComment[] => {
  if (result.code !== 0) return [];
  try {
    const parsed: unknown = JSON.parse(result.stdout);
    return Array.isArray(parsed)
      ? parsed.filter((raw): raw is RawComment => typeof raw === "object" && raw !== null)
      : [];
  } catch {
    return [];
  }
};

/**
 * The checkouts this review's sessions can be listed under: the main one (C1
 * keys the entry on it) first, then the worktree pi runs in.
 * tuicr ties a local session to the checkout it was launched from, so a review
 * started from a worktree is invisible from the main one.
 */
const rootsFor = (cwd: string): string[] => {
  const { root, main } = gitRoots(cwd);
  const primary = main ?? root ?? real(cwd);
  return root === undefined || root === primary ? [primary] : [primary, root];
};

/** Every session of these checkouts, newest first, one listing per slug (main first). */
const probe = async (roots: readonly string[], tuicr: TuicrSource): Promise<Listing[]> => {
  const byslug = new Map<string, Listing>();
  for (const root of roots) {
    for (const found of listedSessions(root, await tuicr.list(root)))
      if (!byslug.has(found.slug)) byslug.set(found.slug, found);
  }
  return [...byslug.values()].sort((a, b) => b.updated - a.updated);
};

/**
 * Sessions that went active for this repository while this pi session ran
 * (D6): `/open diff` starts a review pi never pinned, and its comments still
 * have to reach the inbox after the owner quits tuicr. Process-local on
 * purpose — "during this pi session" is exactly the lifetime of this map.
 */
const wentActive = new Map<string, Candidate[]>();

const sessionKey = (ctx: ExtensionContext, root: string) =>
  `${ctx.sessionManager.getSessionId()}\u0000${root}`;

const remember = (key: string, found: readonly Candidate[]): Candidate[] => {
  const known = wentActive.get(key) ?? [];
  for (const candidate of found)
    if (!known.some((entry) => entry.slug === candidate.slug)) known.push(candidate);
  wentActive.set(key, known);
  return known;
};

const unique = (values: readonly string[]): string[] => [...new Set(values)];

/** Comments tuicr holds for one session, minus what was ingested and what already arrived. */
const freshItems = async (
  tuicr: TuicrSource,
  candidate: Candidate,
  known: ReadonlySet<string>,
): Promise<InboxItem[]> => {
  const items: InboxItem[] = [];
  for (const raw of comments(await tuicr.comments(candidate.root, candidate.slug))) {
    const item = inboxItem(raw);
    if (known.has(item.id) || items.some((seen) => seen.id === item.id)) continue;
    items.push(item);
  }
  return items;
};

const sameIds = (a: readonly string[], b: readonly string[]) =>
  a.length === b.length && a.every((value, index) => value === b[index]);

/** Whether a recorded entry and a rebuilt one say the same thing; `at` is a timestamp, not state. */
const sameReview = (a: ReviewEntry, b: ReviewEntry): boolean =>
  a.root === b.root &&
  a.cwd === b.cwd &&
  a.slug === b.slug &&
  sameIds(a.args, b.args) &&
  a.progress.reviewedCount === b.progress.reviewedCount &&
  a.progress.fileCount === b.progress.fileCount &&
  sameIds(
    a.items.map((item) => item.id),
    b.items.map((item) => item.id),
  ) &&
  sameIds(a.seen, b.seen) &&
  sameIds(a.sent, b.sent);

const NO_PROGRESS: ReviewProgress = { reviewedCount: 0, fileCount: 0 };

/**
 * One ingest: the session's last entry, then what tuicr holds, then what is
 * new in it. Returns the entry as it stands afterwards, or undefined when
 * there was nothing to record.
 */
export const ingestWith = async (
  env: ReviewEnv,
  ctx: ExtensionContext,
  entry: ReviewEntry | undefined,
  tuicr: TuicrSource,
): Promise<ReviewEntry | undefined> => {
  const roots = unique([...(entry === undefined ? [] : [entry.root]), ...rootsFor(ctx.cwd)]);
  const root = roots[0];
  const pinned = entry?.slug ?? null;

  const listed = await probe(roots, tuicr);
  const remembered = remember(
    sessionKey(ctx, root),
    listed
      .filter((session) => session.active)
      .map(({ slug, root: from }) => ({ slug, root: from })),
  );

  const byslug = (slug: string) => listed.find((session) => session.slug === slug);
  // A pin is authoritative: the review the owner picked is the one to read,
  // whatever else went live afterwards. Without one, follow the live review:
  // `/open diff` starts tuicr outside pi, and its comments still belong here.
  const current = pinned !== null ? byslug(pinned) : listed.find((session) => session.active);
  const slug = pinned ?? current?.slug ?? null;

  const candidates: Candidate[] = [];
  const add = (candidate: Candidate) => {
    if (!candidates.some((known) => known.slug === candidate.slug)) candidates.push(candidate);
  };
  if (slug !== null) add({ slug, root: current?.root ?? entry?.root ?? root });
  for (const found of remembered) {
    const session = byslug(found.slug);
    // An ended review with nothing in it is the orphan a SIGTERM leaves
    // behind: no comments to read, and no reason to follow it (notes §4).
    if (session === undefined || (!session.active && session.comments === 0)) continue;
    add({ slug: session.slug, root: session.root });
  }

  const known = new Set(entry?.seen ?? []);
  const fresh: InboxItem[] = [];
  for (const candidate of candidates) {
    const session = byslug(candidate.slug);
    if (session !== undefined && !session.active && session.comments === 0) continue;
    for (const item of await freshItems(tuicr, candidate, known)) {
      if (known.has(item.id)) continue;
      known.add(item.id);
      fresh.push(item);
    }
  }

  const next: ReviewEntry = {
    v: 1,
    root,
    cwd: ctx.cwd,
    harness: "pi",
    slug,
    args: entry?.args ?? [],
    items: [...(entry?.items ?? []), ...fresh],
    seen: [...known],
    sent: entry?.sent ?? [],
    // The reviewer's marks are only visible through `review list`; a listing
    // that no longer exists keeps the last progress rather than claiming zero.
    progress: current?.progress ?? entry?.progress ?? NO_PROGRESS,
    at: new Date().toISOString(),
  };

  // Nothing known and nothing found: no entry to write, and the branch stays clean.
  if (entry === undefined && fresh.length === 0) return undefined;
  if (entry !== undefined && sameReview(entry, next)) return entry;
  recordEntry(env, ctx, next);
  return next;
};

/**
 * What a session start and a finished review call (C6): read the entry, read
 * tuicr, and record what arrived. Persistence is `entry.ts`'s half (A5).
 */
export const ingestReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  await ingestWith(env, ctx, readEntry(env, ctx), cliTuicr);
};
