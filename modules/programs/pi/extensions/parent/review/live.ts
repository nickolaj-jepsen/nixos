/**
 * What the review tells the outside while it holds the terminal (D10): the
 * agent-hub row says the session is asking, with how many comments are waiting
 * and how far the reviewer has got. Pushed before pi's TUI stops, because the
 * review then holds the event loop, and cleared when tuicr quits.
 */
import type { ReviewEnv } from "./env.ts";
import type { ReviewEntry } from "./types.ts";

/** The key the review's wait reason is held under, so anything else can coexist. */
const WAIT_KEY = "review";

/**
 * D10's text: how many comments are in the inbox and how far the reviewer has
 * got through the files. The file half is dropped when the listing has no file
 * count to show.
 */
export const waitText = (entry: ReviewEntry): string => {
  const comments = entry.items.length;
  const commentsText = `${comments} comment${comments === 1 ? "" : "s"}`;
  const { reviewedCount, fileCount } = entry.progress;
  if (fileCount <= 0) return `reviewing · ${commentsText}`;
  return `reviewing · ${commentsText}, ${reviewedCount}/${fileCount} files`;
};

/** What this session's review told the hub, per extension load. */
type Live = { label?: string };

const live = new WeakMap<ReviewEnv, Live>();

const liveOf = (env: ReviewEnv): Live => {
  let entry = live.get(env);
  if (entry === undefined) live.set(env, (entry = {}));
  return entry;
};

/**
 * The review opened or ended: the hub says so from now on. Called with the
 * entry before the TUI is suspended and with `undefined` once tuicr quits.
 * Nothing here waits on tuicr: the label has to be on the hub's socket before
 * `spawnSync` holds the event loop for the whole review.
 */
export const reviewLive = (env: ReviewEnv, entry: ReviewEntry | undefined): void => {
  const state = liveOf(env);
  state.label = entry === undefined ? undefined : waitText(entry);
  env.dialogs?.hold(WAIT_KEY, state.label);
};

/** D10's text while a review holds the terminal; undefined otherwise. */
export const reviewWaitLabel = (env: ReviewEnv): string | undefined => liveOf(env).label;
