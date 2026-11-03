/**
 * The review entry round trip: the last `review` entry on the session branch is
 * the state, and every mutation appends a new one (C1). Until A5 fills this in,
 * nothing is restored or recorded.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";
import type { ReviewEntry } from "./types.ts";

/** The last review entry on the branch, or undefined when the session has none. */
export const readEntry = (env: ReviewEnv, ctx: ExtensionContext): ReviewEntry | undefined =>
  undefined;

/** Restore the review from the branch into this session's state. */
export const restoreReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {};
