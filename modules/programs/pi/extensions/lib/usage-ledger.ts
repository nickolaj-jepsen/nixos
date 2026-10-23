/**
 * Session spend, entry by entry. Pi's own accounting covers assistant messages,
 * tool-result `usage`, usage entries (cache warming), compaction and branch
 * summaries. Two things it cannot see live here as custom entries:
 *
 * - model calls an extension makes on the side (spellfix, session labels),
 *   which never become messages;
 * - which nested tool a codemode script's usage came from: pi merges the usage
 *   of every `ctx.executeTool()` call into the calling tool's result.
 *
 * `entryItems` is the one definition of what an entry costs and what it is
 * attributed to; the footer total and the /cost breakdown both sum it.
 */
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";

export const LEDGER_TYPE = "usage-ledger";

/** A model call made outside the conversation; `source` names the feature that made it. */
export type SideCall = {
  kind: "side";
  source: string;
  provider: string;
  model: string;
  usage: Usage;
};

/**
 * The share of a tool result's usage that came from the calls it made, by the
 * nested tool's name. It only moves spend between tools, never adds to it.
 */
export type NestedSplit = {
  kind: "nested";
  toolCallId: string;
  parts: Array<{ tool: string; usage: Usage }>;
};

export type LedgerData = SideCall | NestedSplit;

export type ItemKind = "conversation" | "upkeep" | "side" | "tool";

export type Item = {
  kind: ItemKind;
  /** Model id for conversation turns, the operation for upkeep, the feature or tool name otherwise. */
  name: string;
  provider?: string;
  model?: string;
  usage: Usage;
  /** A reply that ended in an error or abort; it may still have been billed. */
  failed?: boolean;
  /** The leg of a nested split that takes spend off the calling tool; not a call of its own. */
  transfer?: boolean;
};

export const emptyUsage = (): Usage => ({
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
});

/** A flat fee as usage: no tokens, the whole amount in `cost.total`. */
export const usdUsage = (usd: number): Usage => {
  const usage = emptyUsage();
  usage.cost.total = usd;
  return usage;
};

/** `into` plus `sign` times `add`, in place. */
export const addUsage = (into: Usage, add: Usage | undefined, sign = 1): Usage => {
  if (!add) return into;
  into.input += sign * (add.input ?? 0);
  into.output += sign * (add.output ?? 0);
  into.cacheRead += sign * (add.cacheRead ?? 0);
  into.cacheWrite += sign * (add.cacheWrite ?? 0);
  if (add.cacheWrite1h) into.cacheWrite1h = (into.cacheWrite1h ?? 0) + sign * add.cacheWrite1h;
  into.totalTokens += sign * (add.totalTokens ?? 0);
  into.cost.input += sign * (add.cost?.input ?? 0);
  into.cost.output += sign * (add.cost?.output ?? 0);
  into.cost.cacheRead += sign * (add.cost?.cacheRead ?? 0);
  into.cost.cacheWrite += sign * (add.cost?.cacheWrite ?? 0);
  into.cost.total += sign * (add.cost?.total ?? 0);
  return into;
};

/** Whether `usage` used any tokens or cost anything. */
export const isSpend = (usage: Usage | undefined): usage is Usage =>
  usage !== undefined &&
  (usage.input + usage.output + usage.cacheRead + usage.cacheWrite > 0 ||
    (usage.cost?.total ?? 0) !== 0);

/**
 * Persists the usage of a model call made outside the conversation, attributed
 * to the model that answered (a virtual model's response names the physical
 * one). Calls that used nothing are not recorded.
 */
export const recordSideCall = (pi: ExtensionAPI, source: string, response: AssistantMessage) => {
  if (!isSpend(response.usage)) return;
  const data: SideCall = {
    kind: "side",
    source,
    provider: response.provider,
    model: response.model,
    usage: response.usage,
  };
  try {
    pi.appendEntry<LedgerData>(LEDGER_TYPE, data);
  } catch {
    // No session to write to (shutting down); the spend goes unrecorded.
  }
};

/**
 * What one entry adds to the session's spend. `toolNameOf` resolves the tool
 * behind a nested split's tool call; without it, splits are dropped, which
 * changes attribution but never the total.
 */
export const entryItems = (
  entry: SessionEntry,
  toolNameOf?: (toolCallId: string) => string | undefined,
): Item[] => {
  switch (entry.type) {
    case "message": {
      const message = entry.message;
      if (message.role === "assistant") {
        return [
          {
            kind: "conversation",
            name: message.model,
            provider: message.provider,
            model: message.model,
            usage: message.usage,
            failed: message.stopReason === "error" || message.stopReason === "aborted",
          },
        ];
      }
      if (message.role === "toolResult") {
        if (isSpend(message.usage)) {
          return [{ kind: "tool", name: message.toolName, usage: message.usage }];
        }
        // Results from before a tool reported `usage` carried their fee here.
        const legacy = (message.details as { costUsd?: unknown } | undefined)?.costUsd;
        if (typeof legacy === "number" && legacy > 0) {
          return [{ kind: "tool", name: message.toolName, usage: usdUsage(legacy) }];
        }
      }
      return [];
    }
    case "usage":
      return isSpend(entry.usage)
        ? [
            {
              kind: "upkeep",
              name: entry.kind,
              provider: entry.provider,
              model: entry.model,
              usage: entry.usage,
            },
          ]
        : [];
    case "compaction":
    case "branch_summary":
      return isSpend(entry.usage)
        ? [
            {
              kind: "upkeep",
              name: entry.type === "compaction" ? "compaction" : "branch summary",
              usage: entry.usage,
            },
          ]
        : [];
    case "custom": {
      if (entry.customType !== LEDGER_TYPE) return [];
      const data = entry.data as LedgerData | undefined;
      if (data?.kind === "side" && isSpend(data.usage)) {
        return [
          {
            kind: "side",
            name: data.source,
            provider: data.provider,
            model: data.model,
            usage: data.usage,
          },
        ];
      }
      if (data?.kind === "nested" && toolNameOf) {
        const parent = toolNameOf(data.toolCallId);
        if (!parent) return [];
        return data.parts.flatMap((part) => [
          { kind: "tool" as const, name: part.tool, usage: part.usage },
          {
            kind: "tool" as const,
            name: parent,
            usage: addUsage(emptyUsage(), part.usage, -1),
            transfer: true,
          },
        ]);
      }
      return [];
    }
    default:
      return [];
  }
};

/** The entry's contribution to the session total, in USD. */
export const entryCost = (entry: SessionEntry): number =>
  entryItems(entry).reduce((sum, item) => sum + (item.usage.cost?.total ?? 0), 0);
