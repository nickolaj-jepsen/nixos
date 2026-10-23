/**
 * `/cost`: where this session's money went. A breakdown by conversation model
 * (tokens, cache hits, 1h cache writes), upkeep (compaction, cache warming),
 * extensions' side calls (spellfix, you-should-know, labels) and tools (Exa,
 * subagents, codemode); why (spend per prompt, cache rebuilds, reasoning share,
 * what the re-sent context is made of); then who pays for each provider:
 * prepaid credit, a subscription (spend at list price, with its quota windows),
 * or nothing.
 * A click on the cost in the editor border opens it (chrome/actions.ts).
 *
 * It also records which nested tool a codemode script's usage came from
 * (lib/usage-ledger.ts), since pi merges it all into the script's result.
 */
import type { Usage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { buildBreakdown } from "./cost/breakdown.ts";
import { type Catalog, cacheRebuilds, contextDrivers, thinkingByLevel } from "./cost/insights.ts";
import { type Billing, CostDialog, type ProviderView, type View } from "./cost/dialog.ts";
import { createUsageReader, type UsageProvider } from "./lib/ai-usage.ts";
import { addUsage, emptyUsage, isSpend, LEDGER_TYPE, type LedgerData } from "./lib/usage-ledger.ts";

// Columns of the dialog, borders included; a narrower terminal gets what it has.
const DIALOG_WIDTH = 84;

const billingOf = (quota: UsageProvider | undefined, usd: number): Billing => {
  if (quota?.credit) return "credit";
  if (quota && quota.windows.length > 0) return "subscription";
  return usd === 0 ? "free" : "pay-as-you-go";
};

export default function (pi: ExtensionAPI) {
  let dialog: CostDialog | undefined;
  const quotas = createUsageReader(() => dialog?.refresh());
  /** Window use when the session was opened, by provider and window label. */
  let baseline: Map<string, Map<string, number>> | undefined;
  let openedAt = new Date();
  /** Nested calls' usage by the model-issued call they ran under, until that call ends. */
  const nested = new Map<string, Map<string, Usage>>();

  const snapshot = () =>
    new Map(
      quotas.providers().map((p) => [p.id, new Map(p.windows.map((w) => [w.label, w.usedPct]))]),
    );

  /** The provider's quota as the dialog draws it; growth is measured from the session's open. */
  const quotaView = (
    quota: UsageProvider | undefined,
  ): Pick<ProviderView, "credit" | "windows"> => {
    if (!quota) return {};
    if (quota.credit) {
      return {
        credit: { ...quota.credit, runsOutAt: quota.windows[0]?.runsOutAt ?? undefined },
      };
    }
    const before = baseline?.get(quota.id);
    return {
      windows: quota.windows.map((w) => ({
        label: w.label,
        usedPct: w.usedPct,
        delta: before?.has(w.label) ? w.usedPct - before.get(w.label)! : 0,
      })),
    };
  };

  const view = (ctx: ExtensionContext): View => {
    const entries = ctx.sessionManager.getEntries();
    const catalog: Catalog = (provider, model) => {
      const found = ctx.modelRegistry.find(provider, model);
      return found && { price: found.cost, cacheTtl: found.promptCache };
    };
    const rebuilds = cacheRebuilds(entries, catalog);
    const breakdown = buildBreakdown(
      entries,
      (provider, model) => catalog(provider, model)?.price,
      new Map(rebuilds.map((r) => [r.entryId, r.usd])),
    );
    const contextTokens = ctx.getContextUsage()?.tokens ?? undefined;
    const providers: ProviderView[] = [...breakdown.providers]
      .map(([id, spend]) => {
        const quota = quotas.provider(id);
        return {
          id,
          ...spend,
          billing: billingOf(quota, spend.usd),
          ...quotaView(quota),
        };
      })
      .sort((a, b) => b.usd - a.usd || b.tokens - a.tokens);
    return {
      breakdown,
      providers,
      openedAt,
      rebuilds,
      thinking: thinkingByLevel(entries),
      context: contextDrivers(ctx.sessionManager.getBranch(), contextTokens),
      contextTokens,
      modelName: (provider, model) => ctx.modelRegistry.find(provider, model)?.name || model,
    };
  };

  const open = async (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    if (dialog) return;
    void quotas.refresh();
    try {
      await ctx.ui.custom<void>(
        (tui, theme, _keybindings, done) => {
          dialog = new CostDialog(
            tui,
            theme,
            () => view(ctx),
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
    description: "Session cost: models, cache, side calls, tools and billing",
    handler: async (_args, ctx) => open(ctx),
  });

  pi.on("session_start", () => {
    nested.clear();
    baseline = undefined;
    openedAt = new Date();
    void quotas.refresh().then(() => {
      baseline ??= snapshot();
    });
  });

  pi.on("tool_execution_end", (event) => {
    if (event.parentToolCallId) {
      const usage = (event.result as { usage?: Usage } | undefined)?.usage;
      if (!isSpend(usage)) return;
      // Ids nest as `<model-issued id>/<n>/<m>`; pi credits all of it to the model-issued call.
      const root = event.toolCallId.split("/")[0]!;
      const parts = nested.get(root) ?? new Map<string, Usage>();
      parts.set(event.toolName, addUsage(parts.get(event.toolName) ?? emptyUsage(), usage));
      nested.set(root, parts);
      return;
    }
    const parts = nested.get(event.toolCallId);
    if (!parts) return;
    nested.delete(event.toolCallId);
    try {
      pi.appendEntry<LedgerData>(LEDGER_TYPE, {
        kind: "nested",
        toolCallId: event.toolCallId,
        parts: [...parts].map(([tool, usage]) => ({ tool, usage })),
      });
    } catch {}
  });

  // A new entry may change the numbers under an open dialog.
  pi.on("message_end", () => dialog?.refresh());
  pi.on("agent_end", () => {
    nested.clear();
    dialog?.refresh();
  });
}
