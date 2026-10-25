import { contentText } from "@earendil-works/pi-ai";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { type ItemKind, walkSpend } from "../../shared/usage-ledger.ts";
import type { Rebuilds } from "./rebuilds.ts";

/** The main loop is the conversation and its upkeep (compaction, cache warming). */
export type RowKind = "loop" | Exclude<ItemKind, "conversation" | "upkeep">;

export type Row = {
  kind: RowKind;
  name: string;
  /** Replies, runs, calls or tool results that spent something. */
  calls: number;
  usd: number;
};

/** A prompt with everything spent until the next one. */
export type Turn = {
  text: string;
  usd: number;
  replies: number;
  rebuilds: number;
  /** What the rebuilds cost over cache reads. */
  rebuildUsd: number;
  /** The costliest row it spent on other than the main loop. */
  driver?: { name: string; usd: number; calls: number };
};

export type Breakdown = {
  total: number;
  rows: Row[];
  /** Spend by provider; a tool's fee, which names none, under `TOOL_FEES`. */
  providers: Map<string, { usd: number; tokens: number }>;
  turns: Turn[];
};

export const TOOL_FEES = "tool fees";
const MAIN_LOOP = "main loop";

/**
 * Every entry of the session file. Compaction and branch summaries name no
 * model, so they are put on the provider of the reply before them, which is
 * the one pi uses.
 */
export const buildBreakdown = (entries: readonly SessionEntry[], rebuilds: Rebuilds): Breakdown => {
  const rows = new Map<string, Row>();
  const providers = new Map<string, { usd: number; tokens: number }>();
  const turns: Array<Turn & { drivers: Map<string, { usd: number; calls: number }> }> = [];
  let turn: (typeof turns)[number] | undefined;
  let lastProvider: string | undefined;
  let total = 0;

  walkSpend(entries, (entry, items) => {
    if (entry.type === "message" && entry.message.role === "user") {
      turn = {
        text: contentText(entry.message.content, " ").replace(/\s+/g, " ").trim(),
        usd: 0,
        replies: 0,
        rebuilds: 0,
        rebuildUsd: 0,
        drivers: new Map(),
      };
      turns.push(turn);
    }
    const rebuilt = rebuilds.get(entry.id);
    if (turn && rebuilt !== undefined) {
      turn.rebuilds += 1;
      turn.rebuildUsd += rebuilt;
    }
    // An entry is one call to each row it spends on, however many models it names.
    const counted = new Set<Row>();
    for (const item of items) {
      if (item.kind === "conversation") lastProvider = item.provider;
      const kind: RowKind =
        item.kind === "conversation" || item.kind === "upkeep" ? "loop" : item.kind;
      const loop = kind === "loop";
      const name = loop ? MAIN_LOOP : item.name;
      const key = `${kind}\u0000${name}`;
      let row = rows.get(key);
      if (!row) {
        row = { kind, name, calls: 0, usd: 0 };
        rows.set(key, row);
      }
      const usd = item.usage.cost?.total ?? 0;
      row.usd += usd;
      if (!counted.has(row)) row.calls += 1;
      counted.add(row);
      total += usd;

      const provider =
        item.provider ?? (item.kind === "upkeep" ? lastProvider : undefined) ?? TOOL_FEES;
      const sum = providers.get(provider) ?? { usd: 0, tokens: 0 };
      sum.usd += usd;
      sum.tokens +=
        item.usage.input + item.usage.output + item.usage.cacheRead + item.usage.cacheWrite;
      providers.set(provider, sum);

      if (!turn) continue;
      turn.usd += usd;
      if (item.kind === "conversation") turn.replies += 1;
      if (loop) continue;
      const driver = turn.drivers.get(name) ?? { usd: 0, calls: 0 };
      driver.usd += usd;
      driver.calls += 1;
      turn.drivers.set(name, driver);
    }
  });

  return {
    total,
    rows: [...rows.values()].filter((row) => row.usd > 0).sort((a, b) => b.usd - a.usd),
    providers,
    turns: turns.map(({ drivers, ...rest }) => {
      const [name, top] = [...drivers].sort((a, b) => b[1].usd - a[1].usd)[0] ?? [];
      return { ...rest, driver: name && top ? { name, ...top } : undefined };
    }),
  };
};
