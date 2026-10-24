/**
 * `/cost`: where this session's money went, in one pane: what it cost and how
 * much of that was billed rather than covered by a plan, the quota left in each
 * pool, the spend by feature and subagent role, and the costliest turns with
 * what made each one expensive. A click on the cost in the editor border opens
 * it (chrome/actions.ts).
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { buildBreakdown, TOOL_FEES } from "./cost/breakdown.ts";
import { CostDialog } from "./cost/dialog.ts";
import { cacheRebuilds } from "./cost/rebuilds.ts";
import type { Billing, PoolView, View } from "./cost/view.ts";
import { type UsageProvider, type UsageWindow, usageReader } from "./lib/ai-usage.ts";
import { memoizeOnSession } from "./lib/usage-ledger.ts";

// Columns of the dialog, borders included; a narrower terminal gets what it has.
const DIALOG_WIDTH = 84;

const PACE_RANK: Record<UsageWindow["pace"], number> = { exhausted: 2, over: 1, under: 0 };

const billingOf = (quota: UsageProvider | undefined, id: string, usd: number): Billing => {
  if (quota?.credit) return "credit";
  if (quota && quota.windows.length > 0) return "subscription";
  // A tool's fee is charged per call, plan or not.
  return usd === 0 && id !== TOOL_FEES ? "free" : "pay-as-you-go";
};

/** The window that will stop the pool first: one out, then one over pace, then the fullest. */
const tightest = (windows: readonly UsageWindow[]) =>
  [...windows].sort((a, b) => PACE_RANK[b.pace] - PACE_RANK[a.pace] || b.usedPct - a.usedPct)[0];

export default function (pi: ExtensionAPI) {
  const quotas = usageReader();
  let dialog: CostDialog | undefined;

  const build = (ctx: ExtensionContext): View => {
    const entries = ctx.sessionManager.getEntries();
    const breakdown = buildBreakdown(
      entries,
      cacheRebuilds(entries, (provider, model) => ctx.modelRegistry.find(provider, model)?.cost),
    );
    const providers = [...breakdown.providers]
      .map(([id, spend]) => ({
        id,
        ...spend,
        billing: billingOf(quotas.provider(id), id, spend.usd),
      }))
      .filter((p) => p.usd >= 0.0005 || p.tokens > 0)
      .sort((a, b) => b.usd - a.usd || b.tokens - a.tokens);
    // ai-usage also reads accounts pi has no models for (Claude Code's own plan).
    const configured = new Set(ctx.modelRegistry.getAvailable().map((m) => m.provider));
    const pools = quotas
      .providers()
      .filter((p) => configured.has(p.id) && p.windows.length > 0)
      .map(
        (p): PoolView => ({
          id: p.id,
          window: tightest(p.windows)!,
          credit: p.credit ?? undefined,
        }),
      );
    return { breakdown, providers, pools };
  };
  const view = memoizeOnSession(build, () => String(quotas.stamp()));

  const open = async (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    if (dialog) return;
    void quotas.refresh().then(() => dialog?.refresh());
    try {
      await ctx.ui.custom<void>(
        (tui, theme, _keybindings, done) => {
          dialog = new CostDialog(
            tui,
            theme,
            () => view.get(ctx),
            () => done(),
          );
          return dialog;
        },
        {
          overlay: true,
          // A fixed, readable width: wider only spreads the same columns apart.
          overlayOptions: { anchor: "center", width: DIALOG_WIDTH, margin: 1 },
        },
      );
    } finally {
      dialog = undefined;
    }
  };

  pi.registerCommand("cost", {
    description: "Session cost: billing, quota, spend by feature and role, costliest turns",
    handler: async (_args, ctx) => open(ctx),
  });

  // A new entry may change the numbers under an open dialog.
  pi.on("message_end", () => dialog?.refresh());
  pi.on("agent_end", () => dialog?.refresh());
}
