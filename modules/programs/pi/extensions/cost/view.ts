/**
 * What the pane draws from: this session's spend, how the account pays for it,
 * and the quota left in each pool. Built by `cost.ts`, memoized there; the
 * pane only lays it out.
 */
import type { UsageWindow } from "../lib/ai-usage.ts";
import type { Breakdown } from "./breakdown.ts";

/**
 * Who pays for a provider's tokens. `subscription` spend is the catalog price
 * of what a flat plan covered, not money; `credit` draws down a prepaid grant.
 */
export type Billing = "credit" | "subscription" | "free" | "pay-as-you-go";

export type ProviderView = { id: string; usd: number; tokens: number; billing: Billing };

/** A pool's tightest window, and its balance when it is prepaid credit. */
export type PoolView = {
  id: string;
  window: UsageWindow;
  credit?: { remaining: number; allowance: number };
};

export type View = {
  breakdown: Breakdown;
  providers: ProviderView[];
  pools: PoolView[];
};

/** Money this session actually charged, as opposed to list price on a plan. */
export const billed = (providers: readonly ProviderView[]) =>
  providers
    .filter((p) => p.billing === "credit" || p.billing === "pay-as-you-go")
    .reduce((sum, p) => sum + p.usd, 0);

/** What a flat plan covered, at catalog prices. */
export const onPlans = (providers: readonly ProviderView[]) =>
  providers.filter((p) => p.billing === "subscription").reduce((sum, p) => sum + p.usd, 0);
