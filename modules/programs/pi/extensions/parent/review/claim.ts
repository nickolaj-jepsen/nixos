/**
 * One review per repository: the claim file, taking it over, and the wait
 * reason the agent hub shows while a review is live (U8, U9, D7, D10).
 * Until A6 fills this in, `/review take` says so and the hub hears nothing.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type ReviewEnv, notYet } from "./env.ts";

export const takeClaim = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> =>
  notYet(ctx);

/** D10's text while a review is live; undefined otherwise. */
export const reviewWaitLabel = (env: ReviewEnv): string | undefined => undefined;
