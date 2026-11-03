/**
 * The batch: C5's text prefilled above the draft, and the inbox cleared once a
 * submitted input carries its marker (U2, D4). Until A5 fills this in, the
 * refuse-with-marker contract is a notification and a submitted prompt is left
 * alone.
 */
import type { ExtensionContext, InputEvent } from "@earendil-works/pi-coding-agent";
import { type ReviewEnv, notYet } from "./env.ts";

export const sendBatch = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> =>
  notYet(ctx);

export const reviewInput = async (
  env: ReviewEnv,
  event: InputEvent,
  ctx: ExtensionContext,
): Promise<void> => {};
