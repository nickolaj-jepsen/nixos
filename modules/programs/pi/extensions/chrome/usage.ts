import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import {
  createUsageReader,
  exhaustedWindow,
  type UsageProvider,
  type UsageWindow,
} from "../lib/ai-usage.ts";
import { formatCredit, formatWhen } from "./format.ts";
import type { Part } from "./layout.ts";
import type { ChromeState } from "./state.ts";

/**
 * The one usage fact worth a glance: credit left (always, it is real money),
 * a window that is out, or one that will run dry before it resets.
 */
export const usageAlarm = (
  provider: UsageProvider | undefined,
  now = new Date(),
): Part | undefined => {
  if (!provider) return undefined;
  // A snapshot can outlive the moment a window resets, so every check is against `now`.
  const exhausted = exhaustedWindow(provider, now.getTime());
  if (provider.credit) {
    const { remaining, allowance } = provider.credit;
    const share = allowance > 0 ? remaining / allowance : 1;
    const color: ThemeColor =
      share <= 0.05 || exhausted
        ? "error"
        : share <= 0.2 || provider.windows[0]?.pace === "over"
          ? "warning"
          : "dim";
    return { id: "credit", text: `${formatCredit(remaining)} left`, color };
  }
  if (exhausted) {
    const when = formatWhen(new Date(exhausted.resetsAt), now);
    return {
      id: "quota",
      text: exhausted.meter
        ? `${exhausted.label} out, next top-up ${when}`
        : `${exhausted.label} out until ${when}`,
      color: "error",
    };
  }
  // A meter never runs out on a pace, only on what is left of it.
  const meter = provider.windows.find((w) => w.meter && w.pace !== "under");
  if (meter) {
    return {
      id: "quota",
      text: `${meter.label} ${Math.round(100 - meter.usedPct)}% left`,
      color: "warning",
    };
  }
  const emptying = provider.windows
    .filter(
      (w): w is UsageWindow & { runsOutAt: string } =>
        w.pace === "over" &&
        w.runsOutAt !== null &&
        Date.parse(w.runsOutAt) > now.getTime() &&
        Date.parse(w.runsOutAt) < Date.parse(w.resetsAt),
    )
    .sort((a, b) => Date.parse(a.runsOutAt) - Date.parse(b.runsOutAt))[0];
  if (emptying) {
    const when = formatWhen(new Date(emptying.runsOutAt), now);
    return { id: "quota", text: `${emptying.label} empty ${when}`, color: "warning" };
  }
  return undefined;
};

/** The shared ai-usage snapshot, repainting the footer when it refreshes. */
export const createUsage = (state: ChromeState) => {
  const reader = createUsageReader(() => state.tui?.requestRender());
  return { refresh: () => void reader.refresh(), provider: reader.provider };
};
