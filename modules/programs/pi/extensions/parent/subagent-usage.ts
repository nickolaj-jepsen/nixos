/**
 * Files a subagent's spend where `/cost` and the editor border read it.
 *
 * The agent package shows each child's token total in the widget and in its
 * completion notice, but it does not hand the parent a pi `Usage`, so a child's
 * money never reaches the session total. Pi counts only what it sees as
 * messages, and a child's messages live in its own session file.
 *
 * So this reads each child's transcript with the ledger's own `entryItems`
 * (`shared/usage-ledger.ts`), which counts its replies, tool fees, compaction,
 * cache warming and side calls, and files the whole transcript's spend so far
 * as one entry. Readers count only the latest entry per transcript, so a
 * resumed child or a `/reload` filing it again never counts it twice.
 *
 * Parent-only: a child's hooks return rather than filing a grandchild's spend twice.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  type ExtensionAPI,
  type ExtensionContext,
  parseSessionEntries,
} from "@earendil-works/pi-coding-agent";
import { childTranscriptDir } from "../shared/subagent-session.ts";
import {
  addUsage,
  type ChildCall,
  emptyUsage,
  entryItems,
  LEDGER_TYPE,
  type LedgerData,
} from "../shared/usage-ledger.ts";

/** The custom entry the agent package appends for each terminal run. */
const RECORD_TYPE = "subagents:record";

/** A transcript and the agent type that wrote it, `""` when no record names one. */
type Run = { file: string; agent: string };

type Parts = ChildCall["parts"];

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

/** A reading as text, so a new one can be told apart from the last one filed. */
const readingKey = (agent: string, parts: Parts) => JSON.stringify([agent, parts]);

/** The latest reading filed for each transcript, and the file's size and mtime when it was read. */
type Filed = { key: string; agent: string; stamp?: string };

const filed = (ctx: ExtensionContext): Map<string, Filed> => {
  const byFile = new Map<string, Filed>();
  for (const entry of ctx.sessionManager.getEntries()) {
    if (entry.type !== "custom" || entry.customType !== LEDGER_TYPE) continue;
    const data = entry.data as LedgerData | undefined;
    if (data?.kind === "child")
      byFile.set(data.file, {
        key: readingKey(data.agent, data.parts),
        agent: data.agent,
        stamp: data.stamp,
      });
  }
  return byFile;
};

const stampOf = (file: string): string | undefined => {
  try {
    const stat = statSync(file);
    return `${stat.size}:${stat.mtimeMs}`;
  } catch {
    return undefined;
  }
};

/** One child transcript's whole spend, by the model that spent it. */
const readTranscript = (file: string): Parts | undefined => {
  let text: string;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    // An unsaved parent keeps its children's transcripts in a temp dir, and a
    // session restored elsewhere may point at one this machine never had.
    return undefined;
  }
  const groups = new Map<string, Parts[number]>();
  // Compaction and branch summaries name no model; file them on the reply before them, as /cost does.
  let last = { provider: "", model: "" };
  for (const entry of parseSessionEntries(text)) {
    if (entry.type === "session") continue;
    for (const item of entryItems(entry)) {
      if (item.kind === "conversation")
        last = { provider: item.provider ?? "", model: item.model ?? "" };
      const fallback = item.kind === "upkeep" ? last : { provider: "", model: "" };
      const provider = item.provider ?? fallback.provider;
      const model = item.model ?? fallback.model;
      const key = `${provider}/${model}`;
      const group = groups.get(key) ?? { provider, model, usage: emptyUsage() };
      addUsage(group.usage, item.usage);
      groups.set(key, group);
    }
  }
  return [...groups.values()];
};

/**
 * Parsed transcripts by file, so a run that settles twice does not re-read a
 * megabyte each time; a child that resumes grows its file and misses the cache.
 */
const cache = new Map<string, { stamp: string; parts: Parts | undefined }>();

const cachedTranscript = (file: string, stamp: string): Parts | undefined => {
  const hit = cache.get(file);
  if (hit?.stamp === stamp) return hit.parts;
  const parts = readTranscript(file);
  cache.set(file, { stamp, parts });
  return parts;
};

export default function (pi: ExtensionAPI) {
  /**
   * Files each child's reading where it differs from the last one filed.
   * `sweep` also files transcripts no record names, at the cost of an agent label.
   */
  const file = (ctx: ExtensionContext, sweep = false) => {
    const latest = filed(ctx);
    const recorded = recordedRuns(ctx);
    const runs = [...recorded.values(), ...(sweep ? unrecordedRuns(ctx, recorded) : [])];
    for (const run of runs) {
      const stamp = stampOf(run.file);
      const last = latest.get(run.file);
      // Unchanged since it was filed, even by an earlier process: no need to read it.
      if (!stamp || (last?.stamp === stamp && last.agent === run.agent)) continue;
      const parts = cachedTranscript(run.file, stamp);
      if (!parts || parts.length === 0) continue;
      if (last?.key === readingKey(run.agent, parts)) continue;
      try {
        pi.appendEntry<LedgerData>(LEDGER_TYPE, {
          kind: "child",
          file: run.file,
          agent: run.agent,
          parts,
          stamp,
        });
      } catch {
        // No session to write to (shutting down); the spend goes unrecorded.
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
