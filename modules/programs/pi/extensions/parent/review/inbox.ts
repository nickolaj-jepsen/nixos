/**
 * The inbox's two surfaces (D3, D10): the segment on the editor's border and the
 * overlay behind it.
 *
 * The meter is what the border paints through `measurements()`, so it has no
 * `ctx`: it reads the entry A5's `sessionReview()` publishes for exactly this
 * reason. What it counts is what has not been delivered yet — the same pending
 * set `/review send` batches — so a delivered comment leaves the count and the
 * progress half stays.
 *
 * The overlay lists every comment the review holds, and enter leaves for the
 * review itself through A2's opener: `openReview` with no scope attaches the
 * running tuicr, which is the hop the owner wants from the list.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Meter } from "../chrome/measurements.ts";
import type { ReviewEnv } from "./env.ts";
import { readEntry, sessionReview } from "./entry.ts";
import { type InboxResult, InboxOverlay, locate, shownLocation } from "./overlay.ts";
import type { ReviewProgress } from "./types.ts";
import { type InboxItem, type ReviewEntry } from "./types.ts";
import { openReview } from "./tuicr.ts";

/** `5/7 files`, or nothing when the listing has no file count to show (as D10's hub text does). */
const progressText = ({ reviewedCount, fileCount }: ReviewProgress) =>
  fileCount > 0 ? `${reviewedCount}/${fileCount}` : undefined;

/** The comments ingested but not handed to the model yet, which is what "new" counts (D4). */
const pendingOf = (entry: ReviewEntry): InboxItem[] =>
  entry.items.filter((item) => !entry.sent.includes(item.id));

/**
 * D3/D10: `review 2 new · 5/7` while comments are waiting, `review 5/7` once
 * they have all gone to the model, and nothing at all without a review.
 *
 * The border paints every meter dim and lights a clickable one under the
 * pointer, so "dim when nothing is new" is the segment without a `N new` count
 * and without the action that would light it: there is nothing to click through
 * to. The text carries no colour of its own — `theme.fg` around it would end its
 * own span mid-row.
 */
export const inboxMeter = (env: ReviewEnv): Meter | undefined => {
  const entry = sessionReview();
  if (entry === undefined) return undefined;
  const progress = progressText(entry.progress);
  const pending = pendingOf(entry).length;
  if (pending === 0)
    return progress === undefined ? undefined : { id: "review", text: `review ${progress}` };
  const text =
    progress === undefined ? `review ${pending} new` : `review ${pending} new · ${progress}`;
  const action = (ctx: ExtensionContext) => openInbox(env, ctx);
  return { id: "review", text, action };
};

/**
 * `/review inbox` and the segment's click: the list over the whole terminal,
 * then either back to the prompt or on into the review (D3, D11).
 */
export const openInbox = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  if (ctx.mode !== "tui" || !ctx.hasUI) return;
  const entry = readEntry(env, ctx);
  if (entry === undefined || entry.items.length === 0) {
    ctx.ui.notify("review: the inbox is empty", "info");
    return;
  }
  const result = await ctx.ui.custom<InboxResult>(
    (tui, theme, _keybindings, done) =>
      new InboxOverlay(
        { rows: tui.terminal.rows, requestRender: () => tui.requestRender() },
        theme,
        entry.items,
        new Set(entry.sent),
        done,
        (item) => void copyLocation(ctx, item),
      ),
    { overlay: false },
  );
  if (result === "attach") await openReview(env, ctx, undefined);
};

/**
 * pi's clipboard writer, loaded when `y` needs it: the package's root entry
 * drags the whole runtime in with it, and `node --test` loads this module for
 * the meter and the overlay's rendering.
 */
const clipboard = async (): Promise<((text: string) => Promise<void>) | undefined> => {
  try {
    const pi: typeof import("@earendil-works/pi-coding-agent") =
      await import("@earendil-works/pi-coding-agent");
    return pi.copyToClipboard;
  } catch {
    return undefined;
  }
};

/**
 * `y`: the comment's location on the terminal's clipboard, then the notice that
 * says what was copied. A comment without a file has no location to copy, and a
 * terminal with no clipboard route says so instead of pretending.
 */
const copyLocation = async (ctx: ExtensionContext, item: InboxItem): Promise<void> => {
  const where = locate(item);
  if (where === undefined) {
    ctx.ui.notify("review: this comment has no file to copy", "info");
    return;
  }
  const write = await clipboard();
  if (write === undefined) {
    ctx.ui.notify("review: no clipboard in this session", "error");
    return;
  }
  try {
    await write(where);
  } catch (error) {
    ctx.ui.notify(`review: ${error instanceof Error ? error.message : String(error)}`, "error");
    return;
  }
  // A notice is drawn too, and a path can carry escape bytes from another process (B1).
  ctx.ui.notify(`copied ${shownLocation(item) ?? where}`, "info");
};
