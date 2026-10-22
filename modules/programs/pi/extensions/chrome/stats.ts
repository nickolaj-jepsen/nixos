import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

type ActiveModel = NonNullable<ExtensionContext["model"]>;

export type Stats = {
  cost: number;
  cacheRead: number;
  /** Hit rate of the latest request that could have hit a warm cache. */
  cacheHit: number | undefined;
  speed: number | undefined;
};

// A short reply is mostly time-to-first-token, and a small prompt makes a hit
// rate noisy. Only show diagnostics once the sample means something.
const MIN_SPEED_OUTPUT_TOKENS = 100;
const MIN_CACHE_PROMPT_TOKENS = 2000;

const addUsage = (
  totals: { cost: number; cacheRead: number },
  usage: { cacheRead: number; cost?: { total: number } } | undefined,
) => {
  if (!usage) return;
  totals.cost += usage.cost?.total ?? 0;
  totals.cacheRead += usage.cacheRead;
};

const collectStats = (ctx: ExtensionContext, model: ActiveModel | undefined): Stats => {
  const totals = { cost: 0, cacheRead: 0 };
  let cacheHit: number | undefined;
  let lastSpeed: { provider: string; model: string; value: number } | undefined;
  // The first request after a start, a model switch or a compaction can only
  // write the cache, so it says nothing about the hit rate.
  let warmModel: string | undefined;

  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type === "usage") {
      addUsage(totals, entry.usage);
    } else if (entry.type === "message") {
      const message = entry.message;
      if (message.role === "assistant") {
        addUsage(totals, message.usage);
        const key = `${message.provider}/${message.model}`;
        const prompt = message.usage.input + message.usage.cacheRead + message.usage.cacheWrite;
        if (key !== warmModel) {
          warmModel = key;
          cacheHit = undefined;
        } else if (prompt >= MIN_CACHE_PROMPT_TOKENS) {
          cacheHit = (message.usage.cacheRead / prompt) * 100;
        }
        if (
          message.usage.output >= MIN_SPEED_OUTPUT_TOKENS &&
          message.stopReason !== "error" &&
          message.stopReason !== "aborted"
        ) {
          const seconds = (Date.parse(entry.timestamp) - message.timestamp) / 1000;
          if (Number.isFinite(seconds) && seconds >= 0.5) {
            lastSpeed = {
              provider: message.provider,
              model: message.model,
              value: message.usage.output / seconds,
            };
          }
        }
      } else if (message.role === "toolResult") {
        addUsage(totals, message.usage);
        // Tools that bill their own API report it here, since no usage block carries it.
        const spent = (message.details as { costUsd?: unknown } | undefined)?.costUsd;
        if (typeof spent === "number") totals.cost += spent;
      }
    } else if (entry.type === "compaction" || entry.type === "branch_summary") {
      if (entry.usage) addUsage(totals, entry.usage);
      warmModel = undefined;
      cacheHit = undefined;
    }
  }

  // A speed from another model would read as the current model's.
  const speed =
    model && lastSpeed?.provider === model.provider && lastSpeed.model === model.id
      ? lastSpeed.value
      : undefined;

  return { ...totals, cacheHit, speed };
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
