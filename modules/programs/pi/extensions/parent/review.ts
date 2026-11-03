/**
 * `/review`: the review round trip's front door (HANDOFF C6). It owns the
 * command's grammar and hands each branch to the module that does the work;
 * the modules own their own files, so this file stays the only wiring.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Meter } from "./chrome/measurements.ts";
import type { ChromeState } from "./chrome/state.ts";
import type { Services } from "./services.ts";
import { reviewInput, sendBatch } from "./review/batch.ts";
import { reviewWaitLabel, takeClaim } from "./review/claim.ts";
import { parseReview } from "./review/command.ts";
import type { ReviewEnv } from "./review/env.ts";
import { restoreReview } from "./review/entry.ts";
import { ingestReview } from "./review/ingest.ts";
import { inboxMeter, openInbox } from "./review/inbox.ts";
import { killReview, openReview, shutdownReview } from "./review/tuicr.ts";

/** What the chrome paints and routes: the border meter, the command, and the session hooks. */
export type Review = {
  meter(): Meter | undefined;
  dispatch(args: string, ctx: ExtensionContext): Promise<void>;
  ingest(ctx: ExtensionContext): Promise<void>;
  shutdown(): Promise<void>;
  waitLabel(): string | undefined;
};

export const createReview = (
  pi: ExtensionAPI,
  state: ChromeState,
  { dialogs, hub }: Pick<Services, "dialogs" | "hub">,
): Review => {
  const env: ReviewEnv = { pi, state, dialogs, hub };
  const review: Review = {
    meter: () => inboxMeter(env),
    dispatch: async (args, ctx) => {
      const parsed = await parseReview(args, ctx);
      switch (parsed.kind) {
        case "none":
          return;
        case "refused":
          ctx.ui.notify(parsed.why, "error");
          return;
        case "open":
          return openReview(env, ctx, parsed.scope);
        case "inbox":
          return openInbox(env, ctx);
        case "send":
          return sendBatch(env, ctx);
        case "take":
          return takeClaim(env, ctx);
        case "kill":
          return killReview(env, ctx);
      }
    },
    ingest: async (ctx) => {
      // The entry first: what the session already knew is the floor for this ingest.
      await restoreReview(env, ctx);
      await ingestReview(env, ctx);
    },
    shutdown: () => shutdownReview(env),
    waitLabel: () => reviewWaitLabel(env),
  };
  // The submitted-prompt hook registers here so the handle keeps C6's shape.
  pi.on("input", (event, ctx) => reviewInput(env, event, ctx));
  return review;
};
