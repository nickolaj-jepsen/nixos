/**
 * The inbox's two surfaces: the border meter and the overlay that lists every
 * comment (D3, D10). Until A4 fills this in, the meter is absent and the
 * overlay says so.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Meter } from "../chrome/measurements.ts";
import { type ReviewEnv, notYet } from "./env.ts";

export const inboxMeter = (env: ReviewEnv): Meter | undefined => undefined;

export const openInbox = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> =>
  notYet(ctx);
