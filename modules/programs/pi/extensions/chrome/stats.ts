import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { entryCost } from "../lib/usage-ledger.ts";

type ActiveModel = NonNullable<ExtensionContext["model"]>;

export type Stats = {
  cost: number;
  /** Hit rate of the latest request that could hit a warm cache, from a model that reports caching. */
  cacheHit: number | undefined;
  speed: number | undefined;
};

// A short reply is mostly time-to-first-token, and a small prompt makes a hit
// rate noisy. Only show diagnostics once the sample means something.
const MIN_SPEED_OUTPUT_TOKENS = 100;
const MIN_CACHE_PROMPT_TOKENS = 2000;

const collectStats = (ctx: ExtensionContext, model: ActiveModel | undefined): Stats => {
  let cost = 0;
  let cacheHit: number | undefined;
  let lastSpeed: { provider: string; model: string; value: number } | undefined;
  // The first request after a start, a model switch or a compaction can only
  // write the cache, so it says nothing about the hit rate.
  let warmModel: string | undefined;
  // A provider that never reports cache usage would read as a permanent 0% hit rate.
  const caching = new Set<string>();

  for (const entry of ctx.sessionManager.getEntries()) {
    cost += entryCost(entry);
    if (entry.type === "compaction" || entry.type === "branch_summary") {
      warmModel = undefined;
      cacheHit = undefined;
      continue;
    }
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    const message = entry.message;
    const key = `${message.provider}/${message.model}`;
    const prompt = message.usage.input + message.usage.cacheRead + message.usage.cacheWrite;
    if (message.usage.cacheRead + message.usage.cacheWrite > 0) caching.add(key);
    if (key !== warmModel) {
      warmModel = key;
      cacheHit = undefined;
    } else if (prompt >= MIN_CACHE_PROMPT_TOKENS) {
      cacheHit = (message.usage.cacheRead / prompt) * 100;
    }
    // Not the entry's timestamp: pi persists a message up to minutes after its stream ends.
    if (
      message.durationMs !== undefined &&
      message.durationMs >= 500 &&
      message.usage.output >= MIN_SPEED_OUTPUT_TOKENS &&
      message.stopReason !== "error" &&
      message.stopReason !== "aborted"
    ) {
      lastSpeed = {
        provider: message.provider,
        model: message.model,
        value: message.usage.output / (message.durationMs / 1000),
      };
    }
  }

  // A speed from another model would read as the current model's.
  const speed =
    model && lastSpeed?.provider === model.provider && lastSpeed.model === model.id
      ? lastSpeed.value
      : undefined;

  return { cost, cacheHit: warmModel && caching.has(warmModel) ? cacheHit : undefined, speed };
};

/** Session cost, cache health and speed, rescanned only when the leaf or model moves. */
export const createStats = () => {
  let cache:
    | { sessionId: string; leafId: string | null; modelKey: string; stats: Stats }
    | undefined;

  const statsFor = (ctx: ExtensionContext, model: ActiveModel | undefined): Stats => {
    // Entries are append-only and every append moves the leaf, so leaf + model
    // is enough to know the scan is still current.
    const sessionId = ctx.sessionManager.getSessionId();
    const leafId = ctx.sessionManager.getLeafId();
    const modelKey = model ? `${model.provider}/${model.id}` : "";
    if (
      cache &&
      cache.sessionId === sessionId &&
      cache.leafId === leafId &&
      cache.modelKey === modelKey
    ) {
      return cache.stats;
    }
    const stats = collectStats(ctx, model);
    cache = { sessionId, leafId, modelKey, stats };
    return stats;
  };

  const reset = () => {
    cache = undefined;
  };

  return { statsFor, reset };
};
