/**
 * `ai-usage --json` (pkgs/ai-usage), whose provider ids match pi's: the quota
 * windows and credit of each subscription, shared by the footer and the routers.
 */
import { execFile } from "node:child_process";

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

// ai-usage caches for 2 minutes; poll no faster than this.
const USAGE_TTL_MS = 60_000;

const readUsage = (stdout: string): UsageProvider[] => {
  try {
    return (JSON.parse(stdout) as { providers?: UsageProvider[] }).providers ?? [];
  } catch {
    return [];
  }
};

/** The window that blocks longest among those used up and not yet reset. */
export const exhaustedWindow = (
  provider: UsageProvider | undefined,
  now = Date.now(),
): UsageWindow | undefined =>
  provider?.windows
    .filter((w) => (w.pace === "exhausted" || w.usedPct >= 100) && Date.parse(w.resetsAt) > now)
    .sort((a, b) => Date.parse(b.resetsAt) - Date.parse(a.resetsAt))[0];

/**
 * A background-refreshed snapshot. `refresh()` resolves once the snapshot is
 * fresh; without ai-usage on PATH every provider reads as unknown.
 */
export const createUsageReader = (onUpdate?: () => void) => {
  let usage: { providers: UsageProvider[]; at: number } | undefined;
  let inflight: Promise<void> | undefined;

  const refresh = (): Promise<void> => {
    if (usage && Date.now() - usage.at < USAGE_TTL_MS) return Promise.resolve();
    inflight ??= new Promise<void>((resolve) => {
      execFile("ai-usage", ["--json"], { timeout: 5000, maxBuffer: 1 << 20 }, (error, stdout) => {
        usage = { providers: error ? [] : readUsage(stdout), at: Date.now() };
        inflight = undefined;
        onUpdate?.();
        resolve();
      });
    });
    return inflight;
  };

  const provider = (id: string) => usage?.providers.find((p) => p.id === id);

  return { refresh, provider, known: () => usage !== undefined };
};
