/**
 * Files a subagent's spend where `/cost` and the editor border read it.
 *
 * The agent package shows each child's token total in the widget and in its
 * completion notice, but it does not hand the parent a pi `Usage`, so a child's
 * money never reaches the session total. Pi counts only what it sees as
 * messages, and a child's messages live in its own session file.
 *
 * So this reads each finished child's transcript and records the assistant
 * messages it finds as ledger entries (`lib/usage-ledger.ts`), keeping the real
 * provider, cache and cost figures. An entry says how many of that transcript's
 * messages it accounts for, which is what makes the read idempotent: a resumed
 * child appends to the same transcript, a `/reload` re-runs this, and either way
 * only the messages no entry has claimed yet are added.
 *
 * Parent-only. A child gets no `subagent` tool, so every hook below returns
 * there rather than filing a grandchild's spend twice.
 */
import { readFileSync, statSync } from "node:fs";
import type { Usage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { addUsage, emptyUsage, LEDGER_TYPE, type LedgerData } from "./lib/usage-ledger.ts";

/** The custom entry the agent package appends for each terminal run. */
const RECORD_TYPE = "subagents:record";

/** A transcript keeps growing only while its agent runs; past this, stop reading it. */
const MAX_TRANSCRIPT_BYTES = 32 * 1024 * 1024;

type RunRecord = { file: string; agent: string };

/** One transcript, as the usage of each assistant message per `provider/model`. */
type Transcript = Map<string, Usage[]>;

const key = (provider: string, model: string) => `${provider}/${model}`;

/** Terminal runs recorded in this session, one per transcript. */
const runRecords = (ctx: ExtensionContext): RunRecord[] => {
  const records = new Map<string, RunRecord>();
  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type !== "custom" || entry.customType !== RECORD_TYPE) continue;
    const data = entry.data as { type?: unknown; outputFile?: unknown } | undefined;
    if (typeof data?.outputFile !== "string" || data.outputFile === "") continue;
    records.set(data.outputFile, {
      file: data.outputFile,
      agent: typeof data.type === "string" ? data.type : "",
    });
  }
  return [...records.values()];
};

/** Messages each recorded model already accounts for, by transcript. */
const claimed = (ctx: ExtensionContext): Map<string, Map<string, number>> => {
  const byFile = new Map<string, Map<string, number>>();
  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type !== "custom" || entry.customType !== LEDGER_TYPE) continue;
    const data = entry.data as LedgerData | undefined;
    if (data?.kind !== "child") continue;
    const counts = byFile.get(data.file) ?? new Map<string, number>();
    counts.set(key(data.provider, data.model), data.messages);
    byFile.set(data.file, counts);
  }
  return byFile;
};

/** Assistant-message usage in one child transcript, in the order it was spent. */
const readTranscript = (file: string): Transcript | undefined => {
  let text: string;
  try {
    if (statSync(file).size > MAX_TRANSCRIPT_BYTES) return undefined;
    text = readFileSync(file, "utf8");
  } catch {
    // A transcript is retained for minutes after a run, and a session restored
    // elsewhere may point at one this machine no longer has.
    return undefined;
  }
  const transcript: Transcript = new Map();
  for (const line of text.split("\n")) {
    if (line === "") continue;
    let entry: unknown;
    try {
      entry = JSON.parse(line);
    } catch {
      continue; // a line still being written
    }
    const message = (
      entry as { message?: { role?: string; provider?: string; model?: string; usage?: Usage } }
    ).message;
    if (message?.role !== "assistant" || !message.usage || !message.provider || !message.model)
      continue;
    const id = key(message.provider, message.model);
    transcript.set(id, [...(transcript.get(id) ?? []), message.usage]);
  }
  return transcript;
};

/**
 * Parsed transcripts by file, so a run that settles twice does not re-read a
 * megabyte each time; a child that resumes grows its file and misses the cache.
 */
const cache = new Map<string, { stamp: string; transcript: Transcript | undefined }>();

const cachedTranscript = (file: string): Transcript | undefined => {
  let stamp: string;
  try {
    const stat = statSync(file);
    stamp = `${stat.size}:${stat.mtimeMs}`;
  } catch {
    return undefined;
  }
  const hit = cache.get(file);
  if (hit?.stamp === stamp) return hit.transcript;
  const transcript = readTranscript(file);
  cache.set(file, { stamp, transcript });
  return transcript;
};

const hasSpend = (usage: Usage) =>
  usage.input + usage.output + usage.cacheRead + usage.cacheWrite > 0 ||
  (usage.cost?.total ?? 0) !== 0;

export default function (pi: ExtensionAPI) {
  let parent = false;

  /** Records whatever of the children's spend no entry has accounted for yet. */
  const file = (ctx: ExtensionContext) => {
    if (!parent) return;
    const alreadyClaimed = claimed(ctx);
    for (const record of runRecords(ctx)) {
      const transcript = cachedTranscript(record.file);
      if (!transcript) continue;
      const counts = alreadyClaimed.get(record.file) ?? new Map<string, number>();
      for (const [id, usages] of transcript) {
        const unclaimed = usages.slice(counts.get(id) ?? 0);
        if (unclaimed.length === 0) continue;
        const usage = emptyUsage();
        for (const spent of unclaimed) addUsage(usage, spent);
        if (!hasSpend(usage)) continue;
        const slash = id.indexOf("/");
        try {
          pi.appendEntry<LedgerData>(LEDGER_TYPE, {
            kind: "child",
            file: record.file,
            agent: record.agent,
            messages: usages.length,
            provider: id.slice(0, slash),
            model: id.slice(slash + 1),
            usage,
          });
        } catch {
          // No session to write to (shutting down); the spend goes unrecorded.
        }
      }
    }
  };

  pi.on("session_start", (_event, ctx) => {
    // The agent core never gives a child the tool that spawns agents.
    parent = pi.getAllTools().some((tool) => tool.name === "subagent");
    file(ctx);
  });

  // Once per run, after pi's own follow-up work is done: a background agent's
  // record is appended when it finishes, which is before the run its completion
  // notice starts.
  pi.on("agent_settled", (_event, ctx) => file(ctx));
  pi.on("session_shutdown", (_event, ctx) => file(ctx));
}
