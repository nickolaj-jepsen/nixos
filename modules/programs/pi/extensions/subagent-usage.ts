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
 * Parent-only: a child's hooks return rather than filing a grandchild's spend twice.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { Usage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { childTranscriptDir, isSubagentSession } from "./lib/subagent-session.ts";
import { addUsage, emptyUsage, isSpend, LEDGER_TYPE, type LedgerData } from "./lib/usage-ledger.ts";

/** The custom entry the agent package appends for each terminal run. */
const RECORD_TYPE = "subagents:record";

/** A transcript and the agent type that wrote it, `""` when no record names one. */
type Run = { file: string; agent: string };

/** One transcript, as the usage of each assistant message per `provider/model`. */
type Transcript = Map<string, Usage[]>;

const key = (provider: string, model: string) => `${provider}/${model}`;

/** Terminal runs recorded in this session, one per transcript. */
const recordedRuns = (ctx: ExtensionContext): Map<string, Run> => {
  const runs = new Map<string, Run>();
  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type !== "custom" || entry.customType !== RECORD_TYPE) continue;
    const data = entry.data as { type?: unknown; outputFile?: unknown } | undefined;
    if (typeof data?.outputFile !== "string" || data.outputFile === "") continue;
    runs.set(data.outputFile, {
      file: data.outputFile,
      agent: typeof data.type === "string" ? data.type : "",
    });
  }
  return runs;
};

/**
 * Every transcript in this session's child directory. A child still running when
 * the parent quits is aborted without a record reaching this session, so only
 * the directory knows it.
 */
const unrecordedRuns = (ctx: ExtensionContext, recorded: Map<string, Run>): Run[] => {
  const dir = childTranscriptDir(ctx);
  if (!dir) return [];
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return []; // no child has run
  }
  return names
    .filter((name) => name.endsWith(".jsonl"))
    .map((name) => join(dir, name))
    .filter((file) => !recorded.has(file))
    .map((file) => ({ file, agent: "" }));
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
    text = readFileSync(file, "utf8");
  } catch {
    // An unsaved parent keeps its children's transcripts in a temp dir, and a
    // session restored elsewhere may point at one this machine never had.
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

export default function (pi: ExtensionAPI) {
  /**
   * Records whatever of the children's spend no entry has accounted for yet.
   * `sweep` also files transcripts no record names, at the cost of an agent label.
   */
  const file = (ctx: ExtensionContext, sweep = false) => {
    if (isSubagentSession(ctx)) return;
    const alreadyClaimed = claimed(ctx);
    const recorded = recordedRuns(ctx);
    const runs = [...recorded.values(), ...(sweep ? unrecordedRuns(ctx, recorded) : [])];
    for (const run of runs) {
      const transcript = cachedTranscript(run.file);
      if (!transcript) continue;
      const counts = alreadyClaimed.get(run.file) ?? new Map<string, number>();
      for (const [id, usages] of transcript) {
        const unclaimed = usages.slice(counts.get(id) ?? 0);
        if (unclaimed.length === 0) continue;
        const usage = emptyUsage();
        for (const spent of unclaimed) addUsage(usage, spent);
        if (!isSpend(usage)) continue;
        const slash = id.indexOf("/");
        try {
          pi.appendEntry<LedgerData>(LEDGER_TYPE, {
            kind: "child",
            file: run.file,
            agent: run.agent,
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

  pi.on("session_start", (_event, ctx) => file(ctx));

  // Once per run, after pi's own follow-up work is done: a background agent's
  // record is appended when it finishes, which is before the run its completion
  // notice starts. A running child is left for its record, which names its agent.
  pi.on("agent_settled", (_event, ctx) => file(ctx));
  pi.on("session_shutdown", (_event, ctx) => file(ctx, true));
}
