/**
 * Session spend, entry by entry. Pi's own accounting covers assistant messages,
 * tool-result `usage`, usage entries (cache warming), compaction and branch
 * summaries. What it cannot see lives here as custom entries: model calls an
 * extension makes on the side (spellfix, session labels), which never become
 * messages, and subagents' spend, which lives in their own session files.
 *
 * `entryItems` is the one definition of what an entry costs and what it is
 * attributed to, and `walkSpend` the one walk over a session.
 */
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, SessionEntry } from "@earendil-works/pi-coding-agent";

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
 * A subagent's spend so far, read from its transcript and grouped by the model
 * that spent it (`""` for a tool fee, which names none). Each one
 * is cumulative, so only the latest per transcript counts (`walkSpend`).
 */
export type ChildCall = {
  kind: "child";
  file: string;
  agent: string;
  parts: Array<{ provider: string; model: string; usage: Usage }>;
};

export type LedgerData = SideCall | ChildCall;

export type ItemKind = "conversation" | "upkeep" | "side" | "child" | "tool";

export type Item = {
  kind: ItemKind;
  /** Model id for conversation turns, the operation for upkeep, the agent type for a child, the feature or tool name otherwise. */
  name: string;
  provider?: string;
  model?: string;
  usage: Usage;
  /** A reply that ended in an error or abort; it may still have been billed. */
  failed?: boolean;
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
 * What one entry adds to the session's spend, read on its own: a child entry
 * here is its whole reading, superseded or not.
 */
export const entryItems = (entry: SessionEntry): Item[] => {
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
      // Child entries from before readings were cumulative have no `parts`; the next filing supersedes them.
      if (data?.kind === "child" && Array.isArray(data.parts)) {
        return data.parts
          .filter((part) => isSpend(part.usage))
          .map((part) => ({
            kind: "child" as const,
            // A row per agent type, so /cost says what each delegation bought.
            name: data.agent || "unnamed",
            provider: part.provider || undefined,
            model: part.model || undefined,
            usage: part.usage,
          }));
      }
      return [];
    }
    default:
      return [];
  }
};

const childFile = (entry: SessionEntry) => {
  if (entry.type !== "custom" || entry.customType !== LEDGER_TYPE) return undefined;
  const data = entry.data as LedgerData | undefined;
  return data?.kind === "child" ? data.file : undefined;
};

/**
 * Calls `visit` with every entry of the session file, all branches included
 * (abandoned ones were paid for too), and what it adds to the spend. A child
 * entry adds nothing once a later one reads the same transcript.
 */
export const walkSpend = (
  entries: readonly SessionEntry[],
  visit: (entry: SessionEntry, items: Item[]) => void,
) => {
  const latest = new Map<string, string>();
  for (const entry of entries) {
    const file = childFile(entry);
    if (file) latest.set(file, entry.id);
  }
  for (const entry of entries) {
    const file = childFile(entry);
    visit(entry, file && latest.get(file) !== entry.id ? [] : entryItems(entry));
  }
};

/**
 * `compute` cached until the session moves. Entries are append-only and every
 * append moves the leaf, so the session and leaf ids and the entry count, plus
 * `extra` for whatever else `compute` reads, say whether a result is current.
 */
export const memoizeOnSession = <A extends unknown[], T>(
  compute: (ctx: ExtensionContext, ...args: A) => T,
  extra: (...args: A) => string = () => "",
) => {
  let cache: { key: string; value: T } | undefined;
  const get = (ctx: ExtensionContext, ...args: A): T => {
    const session = ctx.sessionManager;
    const key = [
      session.getSessionId(),
      session.getLeafId(),
      session.getEntries().length,
      extra(...args),
    ].join("\n");
    if (cache?.key === key) return cache.value;
    const value = compute(ctx, ...args);
    cache = { key, value };
    return value;
  };
  return { get, reset: () => (cache = undefined) };
};
