/**
 * The review entry round trip: the last `review` entry on the session branch is
 * the state, and every mutation appends a new one (C1). Until A5 fills this in,
 * nothing is restored or recorded.
 *
 * `readEntry` and `recordEntry` are the seam every other module uses: ingest
 * reads what the session already knew before it records what it found, and the
 * opener records the pinned scope and the socket once the review is up.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";
import type { ReviewEntry } from "./types.ts";

/** The last review entry on the branch, or undefined when the session has none. */
export const readEntry = (env: ReviewEnv, ctx: ExtensionContext): ReviewEntry | undefined =>
  undefined;

/** Append a review entry, so a reload, a fork and a restored session see it (C1). */
export const recordEntry = (env: ReviewEnv, ctx: ExtensionContext, entry: ReviewEntry): void => {};

/** Restore the review from the branch into this session's state. */
export const restoreReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {};
