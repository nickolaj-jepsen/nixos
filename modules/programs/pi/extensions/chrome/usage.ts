import { execFile } from "node:child_process";
import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import { formatCredit, formatWhen } from "./format.ts";
import type { Part } from "./layout.ts";
import type { ChromeState } from "./state.ts";

export type UsageWindow = {
  label: string;
  usedPct: number;
  pace: "under" | "over" | "exhausted";
  resetsAt: string;
  runsOutAt: string | null;
};

export type UsageProvider = {
  id: string;
  windows: UsageWindow[];
  credit?: { remaining: number; allowance: number } | null;
};

const LABELS: Record<string, string> = { month: "mo" };
const label = (window: UsageWindow) => LABELS[window.label] ?? window.label;

/**
 * The one usage fact worth a glance: credit left (always, it is real money),
 * a window that is out, or one that will run dry before it resets.
 */
export const usageAlarm = (
  provider: UsageProvider | undefined,
  now = new Date(),
): Part | undefined => {
  if (!provider) return undefined;
  if (provider.credit) {
    const { remaining, allowance } = provider.credit;
    const share = allowance > 0 ? remaining / allowance : 1;
    const pace = provider.windows[0]?.pace;
    const color: ThemeColor =
      share <= 0.05 || pace === "exhausted"
        ? "error"
        : share <= 0.2 || pace === "over"
          ? "warning"
          : "dim";
    return { id: "credit", text: `${formatCredit(remaining)} left`, color };
  }
  // The window that blocks longest is the one that matters.
  const exhausted = provider.windows
    .filter((w) => w.pace === "exhausted")
    .sort((a, b) => Date.parse(b.resetsAt) - Date.parse(a.resetsAt))[0];
  if (exhausted) {
    const when = formatWhen(new Date(exhausted.resetsAt), now);
    return { id: "quota", text: `${label(exhausted)} out until ${when}`, color: "error" };
  }
  const emptying = provider.windows
    .filter(
      (w): w is UsageWindow & { runsOutAt: string } =>
        w.pace === "over" &&
        w.runsOutAt !== null &&
        Date.parse(w.runsOutAt) < Date.parse(w.resetsAt),
    )
    .sort((a, b) => Date.parse(a.runsOutAt) - Date.parse(b.runsOutAt))[0];
  if (emptying) {
    const when = formatWhen(new Date(emptying.runsOutAt), now);
    return { id: "quota", text: `${label(emptying)} empty ${when}`, color: "warning" };
  }
  return undefined;
};

// ai-usage caches for 2 minutes; poll no faster than this, and only on events.
const USAGE_TTL_MS = 60_000;

const readUsage = (stdout: string): UsageProvider[] => {
  try {
    return (JSON.parse(stdout) as { providers?: UsageProvider[] }).providers ?? [];
  } catch {
    return [];
  }
};

/** `ai-usage --json`, whose provider ids match pi's, refreshed in the background. */
export const createUsage = (state: ChromeState) => {
  let usage: { providers: UsageProvider[]; at: number } | undefined;
  let busy = false;

  const refresh = () => {
    if (busy || (usage && Date.now() - usage.at < USAGE_TTL_MS)) return;
    busy = true;
    // Not on PATH when the ai-usage feature is off; that just hides the alarm.
    execFile("ai-usage", ["--json"], { timeout: 5000, maxBuffer: 1 << 20 }, (error, stdout) => {
      busy = false;
      usage = { providers: error ? [] : readUsage(stdout), at: Date.now() };
      state.tui?.requestRender();
    });
  };

  const provider = (id: string) => usage?.providers.find((p) => p.id === id);

  return { refresh, provider };
};
