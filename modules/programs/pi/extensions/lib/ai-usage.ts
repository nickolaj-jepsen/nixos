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
 * fresh; `force` also skips this reader's TTL and ai-usage's own cache, for a
 * caller that knows the snapshot is out of date. Without ai-usage on PATH every
 * provider reads as unknown.
 */
export const createUsageReader = (onUpdate?: () => void) => {
  let usage: { providers: UsageProvider[]; at: number } | undefined;
  let inflight: Promise<void> | undefined;
  let forced: Promise<void> | undefined;

  const read = (force: boolean) =>
    new Promise<void>((resolve) => {
      const started = Date.now();
      const args = force ? ["--json", "--refresh"] : ["--json"];
      // Well above ai-usage's per-request TIMEOUT, so one slow endpoint cannot get the run killed.
      const timeout = force ? 30_000 : 5000;
      execFile("ai-usage", args, { timeout, maxBuffer: 1 << 20 }, (error, stdout) => {
        // A plain read may come from ai-usage's cache, so one that started before a
        // forced read finished must not replace its result.
        if (force || !usage || started >= usage.at) {
          usage = { providers: error ? [] : readUsage(stdout), at: force ? Date.now() : started };
        }
        onUpdate?.();
        resolve();
      });
    });

  const refresh = ({ force = false } = {}): Promise<void> => {
    if (force) {
      // Not the plain read in flight: ai-usage may serve that one from its cache.
      forced ??= read(true).finally(() => (forced = undefined));
      return forced;
    }
    if (usage && Date.now() - usage.at < USAGE_TTL_MS) return Promise.resolve();
    inflight ??= read(false).finally(() => (inflight = undefined));
    return inflight;
  };

  const provider = (id: string) => usage?.providers.find((p) => p.id === id);

  return {
    refresh,
    provider,
    providers: () => usage?.providers ?? [],
    known: () => usage !== undefined,
  };
};
