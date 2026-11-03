/**
 * The review's process life: spawn tuicr under dtach, attach to a running one,
 * save and kill it, and take it down with the session (U1, U7, D8, D12).
 *
 * Until A2 fills this in, the hooks say so and return.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type ReviewEnv, notYet } from "./env.ts";
import type { PinnedScope } from "./types.ts";

/** Open the pinned scope, or attach the review that is already running (D12). */
export const openReview = async (
  env: ReviewEnv,
  ctx: ExtensionContext,
  scope: PinnedScope | undefined,
): Promise<void> => notYet(ctx);

/** Save, then kill the running review (D8). */
export const killReview = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> =>
  notYet(ctx);

/** Idempotent teardown on session end, reload and session replacement (U7). */
export const shutdownReview = async (env: ReviewEnv): Promise<void> => {};
