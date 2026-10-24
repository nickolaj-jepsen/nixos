import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import {
  exhaustedWindow,
  type UsageProvider,
  type UsageWindow,
  usageReader,
} from "../../shared/ai-usage.ts";
import { bucketOf, forecastMovedCloser } from "./forecast.ts";
import { formatCredit, formatWhen } from "./format.ts";
import type { Part } from "./layout.ts";
import type { ChromeState } from "./state.ts";

/** How long a forecast that moved closer holds the footer before going quiet. */
const LIT_MS = 2 * 60_000;

/** A window on pace to run dry before it resets, and the key its forecast is remembered under. */
type Drying = UsageWindow & { runsOutAt: string; key: string };

/**
 * Windows on pace to run dry before they reset, soonest first. Being on pace is
 * not itself news: any use above the window's own average sets it off, so it
 * would hold for the rest of the window. It is the *moving* of the projection
 * that the footer reports, which is why `key` travels with the window.
 */
const dryingOut = (provider: UsageProvider, now: Date): Drying[] =>
  provider.windows
    .filter(
      (w): w is UsageWindow & { runsOutAt: string } =>
        w.pace === "over" &&
        w.runsOutAt !== null &&
        Date.parse(w.runsOutAt) > now.getTime() &&
        Date.parse(w.runsOutAt) < Date.parse(w.resetsAt),
    )
    .sort((a, b) => Date.parse(a.runsOutAt) - Date.parse(b.runsOutAt))
    .map((w) => ({ ...w, key: `${provider.id}:${w.label}` }));

/**
 * The shared ai-usage snapshot, and the alarm worth a glance at it: credit left
 * (always, it is real money), a window that is out, or a forecast that has just
 * moved a whole day closer than the one last reported.
 *
 * A crossing is news for a couple of minutes and then goes quiet, so a month
 * spent above average does not sit there in warning colour until it resets.
 */
export const createUsage = (state: ChromeState) => {
  const reader = usageReader();
  /** The window whose forecast moved closer, while it is still worth the footer. */
  let lit: { key: string; resetsAt: string; until: number } | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  /** The reading each provider's forecasts were last compared at. */
  const compared = new Map<string, number>();

  const wake = (at: number) => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(
      () => {
        timer = undefined;
        state.tui?.requestRender();
      },
      Math.max(0, at - Date.now()),
    );
    timer.unref?.();
  };

  const dismiss = () => {
    if (!lit) return;
    lit = undefined;
    if (timer) clearTimeout(timer);
    timer = undefined;
    state.tui?.requestRender();
  };

  /** Records where every window's forecast points, once per reading. */
  const compare = (provider: UsageProvider, now: Date) => {
    if (lit && now.getTime() >= lit.until) lit = undefined;
    const stamp = reader.stamp();
    if (compared.get(provider.id) === stamp) return;
    compared.set(provider.id, stamp);
    for (const w of dryingOut(provider, now)) {
      if (!forecastMovedCloser(w.key, bucketOf(new Date(w.runsOutAt)), w.resetsAt)) continue;
      // The soonest of them all, which is the one the list already put first.
      if (!lit) lit = { key: w.key, resetsAt: w.resetsAt, until: now.getTime() + LIT_MS };
    }
    if (lit) wake(lit.until);
  };

  const alarm = (provider: UsageProvider | undefined, now = new Date()): Part | undefined => {
    if (!provider) return undefined;
    // Compared even when an alarm below outranks the forecast, so a window spent
    // behind a credit balance does not come back with a stale baseline.
    compare(provider, now);
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
    if (!lit) return undefined;
    if (now.getTime() >= lit.until) {
      lit = undefined;
      return undefined;
    }
    // Repainted from the current reading, so the date stays the one on show. A
    // window that reset is a different window with the same name: the alarm it
    // lit belongs to the cycle that reset, not to the new one.
    const crossed = dryingOut(provider, now).find(
      (w) => w.key === lit?.key && w.resetsAt === lit?.resetsAt,
    );
    if (!crossed) {
      lit = undefined;
      return undefined;
    }
    return {
      id: "quota",
      text: `${crossed.label} dry ${formatWhen(new Date(crossed.runsOutAt), now)}`,
      color: "warning",
      action: dismiss,
    };
  };

  return {
    alarm,
    provider: reader.provider,
    refresh: () => void reader.refresh().then(() => state.tui?.requestRender()),
  };
};
