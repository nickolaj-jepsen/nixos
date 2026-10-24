/**
 * Replies that paid to rebuild the prompt cache: they sent most of the previous
 * reply's context again at full price instead of reading it from the cache.
 */
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

/** Catalog prices per million tokens, as on pi's `Model.cost`. */
export type Price = { input: number; output: number; cacheRead: number; cacheWrite: number };

/** What each rebuild cost over reading the same tokens from the cache, by the reply's entry id. */
export type Rebuilds = Map<string, number>;

// A smaller miss is noise: the newest tool results are always uncached.
const MIN_REBUILD_TOKENS = 2048;
const MIN_REBUILD_SHARE = 0.5;

const promptTokens = (u: Usage) => u.input + u.cacheRead + u.cacheWrite;

/**
 * The reply each reply followed, by entry id; null after a compaction or at the
 * start, where nothing could be cached. Walks parents rather than file order, so
 * a reply on one branch is never compared with a reply on another.
 */
const previousReplies = (entries: readonly SessionEntry[]) => {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const before = new Map<string, AssistantMessage | null>();
  for (const entry of entries) {
    const parent = entry.parentId ? byId.get(entry.parentId) : undefined;
    let previous: AssistantMessage | null = null;
    if (parent?.type === "message" && parent.message.role === "assistant")
      previous = parent.message;
    else if (parent && parent.type !== "compaction") previous = before.get(parent.id) ?? null;
    before.set(entry.id, previous);
  }
  return before;
};

/** Every rebuild in the session file; a cold start or the first reply after a compaction is none. */
export const cacheRebuilds = (
  entries: readonly SessionEntry[],
  priceOf: (provider: string, model: string) => Price | undefined,
): Rebuilds => {
  const before = previousReplies(entries);
  const rebuilds: Rebuilds = new Map();
  for (const entry of entries) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    const reply = entry.message;
    const previous = before.get(entry.id);
    if (!previous) continue;
    const u = reply.usage;
    const prior = promptTokens(previous.usage) + previous.usage.output;
    const expected = Math.min(prior, promptTokens(u));
    const missed = expected - u.cacheRead;
    if (missed < MIN_REBUILD_TOKENS || missed < expected * MIN_REBUILD_SHARE) continue;

    // The missed tokens went in as cache writes where the provider writes, as input otherwise.
    const price = priceOf(reply.provider, reply.model);
    const writeRate = u.cacheWrite > 0 ? u.cost.cacheWrite / u.cacheWrite : undefined;
    const inputRate = u.input > 0 ? u.cost.input / u.input : (price?.input ?? 0) / 1e6;
    const readRate =
      price !== undefined
        ? price.cacheRead / 1e6
        : u.cacheRead > 0
          ? u.cost.cacheRead / u.cacheRead
          : 0;
    rebuilds.set(entry.id, missed * Math.max(0, (writeRate ?? inputRate) - readRate));
  }
  return rebuilds;
};
