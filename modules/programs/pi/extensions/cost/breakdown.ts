import type { Usage } from "@earendil-works/pi-ai";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { addUsage, emptyUsage, entryItems, type ItemKind } from "../lib/usage-ledger.ts";

/** Catalog prices per million tokens, as on pi's `Model.cost`. */
export type Price = { input: number; output: number; cacheRead: number; cacheWrite: number };

export type Row = {
  kind: ItemKind;
  name: string;
  provider?: string;
  model?: string;
  /** Calls, replies or tool results that spent something. */
  calls: number;
  failed: number;
  /** What those failed replies cost; they are usually billed all the same. */
  failedUsd: number;
  usage: Usage;
  /** What the cache reads would have cost at the input price; undefined without a catalog price. */
  saved?: number;
  /**
   * Cost of the 1h-retention writes (`usage.cacheWrite1h`, Anthropic only), billed at twice the
   * input price, and what they cost over the same tokens written for 5 minutes.
   */
  longWrite?: { usd: number; premium: number };
};

/**
 * A prompt with everything spent until the next one; `rebuildUsd` of it went on
 * cache rebuilds, and `drivers` is its spend on the upkeep and tool calls it ran.
 */
export type Prompt = {
  text: string;
  usd: number;
  rebuildUsd: number;
  rebuilds: number;
  drivers: Array<{ name: string; usd: number; calls: number }>;
};

export type Breakdown = {
  total: number;
  rows: Row[];
  /** Model-attributed spend and tokens per provider. */
  providers: Map<string, { usd: number; tokens: number }>;
  /** Every prompt of the session file, in the order they were sent. */
  timeline: Prompt[];
};

const promptText = (content: unknown): string => {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : ""))
    .join(" ");
};

const tokens = (usage: Usage) => usage.input + usage.output + usage.cacheRead + usage.cacheWrite;

/**
 * Every entry of the session file, all branches included: abandoned branches
 * were paid for too. Compaction and branch summaries name no model, so they
 * are put on the model of the reply before them, which is the one pi uses.
 */
export const buildBreakdown = (
  entries: readonly SessionEntry[],
  priceOf: (provider: string, model: string) => Price | undefined,
  rebuilds: ReadonlyMap<string, { usd: number }> = new Map(),
): Breakdown => {
  const toolNames = new Map<string, string>();
  for (const entry of entries) {
    if (entry.type === "message" && entry.message.role === "toolResult") {
      toolNames.set(entry.message.toolCallId, entry.message.toolName);
    }
  }

  const rows = new Map<string, Row>();
  // The drivers a prompt ran, by name, kept off `Prompt` until the walk is done.
  const drafts: Array<Prompt & { index: Map<string, { usd: number; calls: number }> }> = [];
  let prompt: (typeof drafts)[number] | undefined;
  let lastModel: { provider: string; model: string } | undefined;
  let total = 0;

  for (const entry of entries) {
    if (entry.type === "message" && entry.message.role === "user") {
      prompt = {
        text: promptText(entry.message.content).replace(/\s+/g, " ").trim(),
        usd: 0,
        rebuildUsd: 0,
        rebuilds: 0,
        drivers: [],
        index: new Map(),
      };
      drafts.push(prompt);
    }
    const rebuilt = rebuilds.get(entry.id);
    if (prompt && rebuilt) {
      prompt.rebuildUsd += rebuilt.usd;
      prompt.rebuilds += 1;
    }
    for (const item of entryItems(entry, (id) => toolNames.get(id))) {
      if (item.kind === "conversation" && item.provider && item.model) {
        lastModel = { provider: item.provider, model: item.model };
      }
      const provider = item.provider ?? (item.kind === "upkeep" ? lastModel?.provider : undefined);
      const model = item.model ?? (item.kind === "upkeep" ? lastModel?.model : undefined);
      const key = [item.kind, item.kind === "conversation" ? "" : item.name, provider, model].join(
        "\u0000",
      );
      let row = rows.get(key);
      if (!row) {
        row = {
          kind: item.kind,
          name: item.name,
          provider,
          model,
          calls: 0,
          failed: 0,
          failedUsd: 0,
          usage: emptyUsage(),
        };
        rows.set(key, row);
      }
      addUsage(row.usage, item.usage);
      const usd = item.usage.cost?.total ?? 0;
      if (!item.transfer) row.calls += 1;
      if (item.failed) {
        row.failed += 1;
        row.failedUsd += usd;
      }
      total += usd;
      if (!prompt) continue;
      prompt.usd += usd;
      // A prompt's own replies are its cost; only the calls it made are a driver of it.
      if (item.kind === "conversation") continue;
      const driver = prompt.index.get(item.name) ?? { usd: 0, calls: 0 };
      driver.usd += usd;
      if (!item.transfer) driver.calls += 1;
      prompt.index.set(item.name, driver);
    }
  }

  const providers = new Map<string, { usd: number; tokens: number }>();
  for (const row of rows.values()) {
    if (row.provider && row.model) {
      const price = priceOf(row.provider, row.model);
      if (price) {
        row.saved = (row.usage.cacheRead * (price.input - price.cacheRead)) / 1e6;
        // pi's calculateCost: 1h writes at 2x input, the rest at the catalog write price.
        const long = row.usage.cacheWrite1h ?? 0;
        if (long > 0) {
          row.longWrite = {
            usd: (long * price.input * 2) / 1e6,
            premium: (long * (price.input * 2 - price.cacheWrite)) / 1e6,
          };
        }
      }
      const sum = providers.get(row.provider) ?? { usd: 0, tokens: 0 };
      sum.usd += row.usage.cost.total;
      sum.tokens += tokens(row.usage);
      providers.set(row.provider, sum);
    }
  }

  // A tool whose whole spend moved to the calls it made has nothing left to show.
  const kept = [...rows.values()].filter(
    (row) => Math.abs(row.usage.cost.total) > 1e-9 || tokens(row.usage) > 0,
  );
  kept.sort((a, b) => b.usage.cost.total - a.usage.cost.total || tokens(b.usage) - tokens(a.usage));

  return {
    total,
    rows: kept,
    providers,
    timeline: drafts.map(({ text, usd, rebuildUsd, rebuilds, index }) => ({
      text,
      usd,
      rebuildUsd,
      rebuilds,
      drivers: [...index].map(([name, d]) => ({ name, ...d })).sort((a, b) => b.usd - a.usd),
    })),
  };
};
