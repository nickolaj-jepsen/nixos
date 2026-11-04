/**
 * The batch (C5) and the inbox's clear-on-submit (D4, U2): the pending
 * comments become one text in the prompt, and a submitted input carrying its
 * marker line is what delivers them.
 *
 * The batch is only ever text handed to the editor. No comment text reaches a
 * shell, a dtach or a tuicr argv element here (B1), and nothing is delivered to
 * the model mid-review: it waits in the prompt for the owner's Enter.
 */
import type { ExtensionContext, InputEvent } from "@earendil-works/pi-coding-agent";
import { foreignClaim } from "./claim.ts";
import type { ReviewEnv } from "./env.ts";
import { readEntry, recordEntry } from "./entry.ts";
import { type InboxItem, type ReviewEntry, batchMarker, batchText } from "./types.ts";

/** The ids the prefilled batch carried, per session slug: what a later submit delivered. */
const batched = new Map<string, string[]>();

const NOTHING = "review: no comments to send";
const NO_SESSION = "review: no review session to send";

/** What the owner has not been handed yet: everything ingested and not sent (D4). */
const pending = (entry: ReviewEntry): InboxItem[] =>
  entry.items.filter((item) => !entry.sent.includes(item.id));

/**
 * `parent/lib/prompt-store.ts` imports pi for its agent dir, which only the
 * extension host resolves; a plain `node --test` cannot, and then the only
 * draft is the editor's.
 */
const promptStore = async (): Promise<typeof import("../lib/prompt-store.ts") | undefined> => {
  try {
    return await import("../lib/prompt-store.ts");
  } catch {
    return undefined;
  }
};

/**
 * The draft the batch goes above. pi empties the editor before an extension
 * command runs, so the text it held is the one `parent/prompts.ts` recorded for
 * this session: prompt-store writes it 400 ms after the last edit and drops it
 * once the editor has been empty that long.
 */
const draftOf = async (ctx: ExtensionContext): Promise<string> => {
  const live = ctx.ui.getEditorText();
  if (live.trim()) return live;
  const store = await promptStore();
  if (store === undefined) return "";
  return store.readPrompts(ctx.cwd).drafts[ctx.sessionManager.getSessionId()]?.text ?? "";
};

/**
 * `/review send`: the pending comments above whatever the owner already typed,
 * and nothing appended when there is nothing new (U2, D4, D11).
 */
export const sendBatch = async (env: ReviewEnv, ctx: ExtensionContext): Promise<void> => {
  if (ctx.mode !== "tui" || !ctx.hasUI) return;
  // Another session's review: its comments are not this session's to deliver (U8).
  const claim = foreignClaim(env, ctx);
  if (claim !== undefined) {
    ctx.ui.notify(`review: claimed by ${claim}; /review take takes it over`, "info");
    return;
  }
  const entry = readEntry(env, ctx);
  const items = entry === undefined ? [] : pending(entry);
  if (items.length === 0) {
    ctx.ui.notify(NOTHING, "info");
    return;
  }
  if (entry === undefined || entry.slug === null) {
    ctx.ui.notify(NO_SESSION, "error");
    return;
  }
  const batch = batchText(entry.slug, entry.root, items);
  const draft = await draftOf(ctx);
  ctx.ui.setEditorText(draft.trim() ? `${batch}\n\n${draft}` : batch);
  batched.set(
    entry.slug,
    items.map((item) => item.id),
  );
  ctx.ui.notify(
    `review: ${items.length} comment${items.length === 1 ? "" : "s"} prefilled`,
    "info",
  );
};

/**
 * A submitted prompt that carries the batch's marker delivered it: those ids
 * are sent, so the inbox empties instead of handing them over twice (D4). The
 * prompt itself still goes to the model — the batch is the point of sending it.
 */
export const reviewInput = async (
  env: ReviewEnv,
  event: InputEvent,
  ctx: ExtensionContext,
): Promise<void> => {
  const entry = readEntry(env, ctx);
  if (entry === undefined || entry.slug === null) return;
  if (!event.text.includes(batchMarker(entry.slug))) return;
  // The ids the prefill carried, so a comment that arrived while the owner was
  // reading the batch is not marked as delivered. A reload forgets the map, and
  // then everything still pending is what the editor holds.
  const delivered = batched.get(entry.slug) ?? pending(entry).map((item) => item.id);
  batched.delete(entry.slug);
  const sent = [...new Set([...entry.sent, ...delivered])];
  if (sent.length === entry.sent.length) return;
  recordEntry(env, ctx, { ...entry, sent, at: new Date().toISOString() });
};
