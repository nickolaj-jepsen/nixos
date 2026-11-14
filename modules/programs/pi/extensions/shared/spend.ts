/**
 * What a session entry cost, by pi's own accounting: assistant replies,
 * tool-result `usage`, usage entries (cache warming), compaction and branch
 * summaries. Every branch counts, abandoned ones were paid for too.
 */
import type { Usage } from "@earendil-works/pi-ai";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

/** `provider` is absent for spend that names none: a tool fee, compaction, a branch summary. */
export type Spend = { provider?: string; usd: number };

const usd = (usage: Usage | undefined) => usage?.cost?.total ?? 0;

export const entrySpend = (entry: SessionEntry): Spend | undefined => {
  switch (entry.type) {
    case "message": {
      const message = entry.message;
      if (message.role === "assistant")
        return { provider: message.provider, usd: usd(message.usage) };
      if (message.role === "toolResult") return { usd: usd(message.usage) };
      return undefined;
    }
    case "usage":
      return { provider: entry.provider, usd: usd(entry.usage) };
    case "compaction":
    case "branch_summary":
      return { usd: usd(entry.usage) };
    default:
      return undefined;
  }
};
