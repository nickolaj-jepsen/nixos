/**
 * One review per repository: the claim file, taking it over, and the wait
 * reason the agent hub shows while a review is live (U8, U9, D7, D10).
 * Until A6 fills this in, `/review take` says so, no claim is read or written,
 * and the hub hears nothing.
 *
 * `foreignClaim` and `reviewLive` are what the opener asks and tells: who else
 * holds this repository, and that the hub should say a review is running (before
 * the TUI is suspended, because the review then blocks pi's event loop).
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type ReviewEnv, notYet } from "./env.ts";
import type { ReviewEntry } from "./types.ts";

export const takeClaim = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> =>
  notYet(ctx);

/** The live claim another session holds on this repository, if any (U8). */
export const foreignClaim = (env: ReviewEnv, ctx: ExtensionContext): string | undefined =>
  undefined;

/** A review is live (or just ended): the hub's wait reason follows it (D10). */
export const reviewLive = (env: ReviewEnv, entry: ReviewEntry | undefined): void => {};

/** D10's text while a review is live; undefined otherwise. */
export const reviewWaitLabel = (env: ReviewEnv): string | undefined => undefined;
