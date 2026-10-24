/**
 * What a pane draws from: this session's spend, how the account pays for it,
 * and the facts behind both. Built once per render by `cost.ts`; the panes only
 * lay it out.
 */
import type { Breakdown, Row } from "./breakdown.ts";
import type { ContextSource, Rebuild, ThinkingLevelView } from "./insights.ts";

/**
 * Who pays for a provider's tokens. `subscription` spend is the catalog price
 * of what a flat plan covered, not money; `credit` draws down a prepaid grant.
 */
export type Billing = "credit" | "subscription" | "free" | "pay-as-you-go";

export type WindowView = {
  label: string;
  usedPct: number;
  /** Growth since the session opened; a plan's quota is shared with every other session. */
  delta: number;
  resetsAt?: string;
  /** ai-usage's read on the burn rate, which a percentage alone cannot give. */
  pace?: "under" | "over" | "exhausted";
};

export type ProviderView = {
  id: string;
  usd: number;
  tokens: number;
  billing: Billing;
  /** A prepaid balance, from ai-usage. */
  credit?: { remaining: number; allowance: number; runsOutAt?: string };
  /** A plan's quota windows, from ai-usage. */
  windows?: WindowView[];
};

export type View = {
  breakdown: Breakdown;
  providers: ProviderView[];
  /** When the quota baseline was taken; window growth counts from here. */
  openedAt: Date;
  rebuilds: Rebuild[];
  thinking: ThinkingLevelView[];
  /** What the current branch's requests re-sent, by source. */
  context: ContextSource[];
  /** The context's size now, when pi knows it. */
  contextTokens?: number;
  /** The model most of the spend is on, which rows then leave out. */
  dominantModel?: string;
  modelName: (provider: string, model: string) => string;
};

/** Money this session actually charged, as opposed to list price on a plan. */
export const billed = (providers: readonly ProviderView[]) =>
  providers
    .filter((p) => p.billing === "credit" || p.billing === "pay-as-you-go")
    .reduce((sum, p) => sum + p.usd, 0);

/** What a flat plan covered, at catalog prices. */
export const onPlans = (providers: readonly ProviderView[]) =>
  providers.filter((p) => p.billing === "subscription").reduce((sum, p) => sum + p.usd, 0);

/**
 * A row named by what makes it different: conversation rows by their model,
 * everything else by its own name, with the model only when it is not the
 * session's usual one. Two rows can then never truncate into the same text.
 */
export const rowLabel = (view: View, row: Row) => {
  const model = row.provider && row.model ? view.modelName(row.provider, row.model) : undefined;
  if (row.kind === "conversation") return model ?? row.name;
  return row.name + (model && model !== view.dominantModel ? ` · ${model}` : "");
};
