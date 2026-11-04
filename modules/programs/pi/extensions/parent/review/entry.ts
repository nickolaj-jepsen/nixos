/**
 * The review entry round trip: the last `review` entry on the session branch is
 * the state, and every mutation appends a new one (C1). A reload, a fork and a
 * resumed session all rebuild the review from the branch, so nothing here is
 * kept that the branch does not hold.
 *
 * `readEntry` and `recordEntry` are the seam every other module uses: ingest
 * reads what the session already knew before it records what it found, the
 * opener records the tuicr argv and the slug once the review is up, and
 * `restoreReview` publishes the entry to the painters, which have no ctx.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";
import { type InboxItem, REVIEW_ENTRY, type ReviewEntry, type ReviewProgress } from "./types.ts";

/** The entry the last read or write saw; the border meter paints from it. */
let session: ReviewEntry | undefined;

/** The review this session last saw, or undefined when the branch holds none (A4's meter). */
export const sessionReview = (): ReviewEntry | undefined => session;

type Fields = Record<string, unknown>;

const text = (value: unknown): value is string => typeof value === "string";

const fields = (value: unknown): Fields | undefined =>
  typeof value === "object" && value !== null ? (value as Fields) : undefined;

/** A count is a non-negative integer; a line is that or `null`. */
const count = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 0;

const line = (value: unknown) => value === null || count(value);

const nullable = (value: unknown, ok: (field: unknown) => boolean) => value === null || ok(value);

const optionalText = (value: unknown) => value === undefined || text(value);

const isItem = (value: unknown): value is InboxItem => {
  const item = fields(value);
  return (
    item !== undefined &&
    text(item.id) &&
    text(item.body) &&
    text(item.at) &&
    nullable(item.path, text) &&
    nullable(item.type, text) &&
    nullable(item.author, text) &&
    (item.side === null || item.side === "old" || item.side === "new") &&
    line(item.startLine) &&
    line(item.endLine)
  );
};

const isProgress = (value: unknown): value is ReviewProgress => {
  const progress = fields(value);
  return progress !== undefined && count(progress.reviewedCount) && count(progress.fileCount);
};

/**
 * An entry written by another version of this module, or by something that is
 * not this module at all, is not state: the branch is a file on disk.
 */
const isEntry = (value: unknown): value is ReviewEntry => {
  const entry = fields(value);
  return (
    entry !== undefined &&
    entry.v === 1 &&
    entry.harness === "pi" &&
    text(entry.root) &&
    text(entry.cwd) &&
    text(entry.at) &&
    nullable(entry.slug, text) &&
    Array.isArray(entry.args) &&
    entry.args.every(text) &&
    Array.isArray(entry.items) &&
    entry.items.every(isItem) &&
    Array.isArray(entry.seen) &&
    entry.seen.every(text) &&
    Array.isArray(entry.sent) &&
    entry.sent.every(text) &&
    isProgress(entry.progress)
  );
};

/**
 * The last review entry on the branch, or undefined when the session has none.
 * An unreadable record is skipped rather than believed, so a corrupt newest
 * entry falls back to the newest one that still parses.
 */
const latest = (ctx: ExtensionContext): ReviewEntry | undefined => {
  const branch = ctx.sessionManager.getBranch();
  for (let index = branch.length - 1; index >= 0; index -= 1) {
    const entry = branch[index];
    if (entry?.type !== "custom" || entry.customType !== REVIEW_ENTRY) continue;
    if (!isEntry(entry.data)) continue;
    return entry.data;
  }
  return undefined;
};

export const readEntry = (env: ReviewEnv, ctx: ExtensionContext): ReviewEntry | undefined => {
  session = latest(ctx);
  return session;
};

const union = (older: readonly string[], newer: readonly string[]) => [
  ...new Set([...older, ...newer]),
];

/**
 * The entry to append: two writers can overlap (an ingest that waited on tuicr
 * while the owner submitted a batch, the opener while a turn ran), and each
 * holds its own snapshot. Deliveries and ingested ids are only ever added, so
 * their union is kept; the freshest snapshot wins the rest, compared by `at`,
 * which both writers stamp as they write.
 */
const merged = (previous: ReviewEntry | undefined, next: ReviewEntry): ReviewEntry => {
  if (previous === undefined) return next;
  const ids = new Map<string, InboxItem>();
  for (const item of [...previous.items, ...next.items]) ids.set(item.id, item);
  const fresher = next.at >= previous.at ? next : previous;
  const older = fresher === next ? previous : next;
  return {
    ...fresher,
    items: [...ids.values()],
    seen: union(older.seen, fresher.seen),
    sent: union(older.sent, fresher.sent),
  };
};

/** Append a review entry, so a reload, a fork and a restored session see it (C1). */
export const recordEntry = (env: ReviewEnv, ctx: ExtensionContext, entry: ReviewEntry): void => {
  const previous = latest(ctx);
  const appended = merged(previous, entry);
  session = appended;
  env.pi.appendEntry<ReviewEntry>(REVIEW_ENTRY, appended);
};

/** Restore the review from the branch into this session's state. */
export const restoreReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  // session_start: publish what the branch holds, so the meter and the batch
  // have it before the first ingest has anything to add.
  readEntry(env, ctx);
};
