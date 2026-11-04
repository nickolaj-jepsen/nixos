/**
 * FLOW.json's side of /flow: where a flow's plan directory lives, the file's
 * whole read and atomic write, the step records that carry a step's cost across
 * a session switch, and the diff the budget is measured on (C1, C3, D15).
 *
 * The file is the only state a flow keeps: every step is a new session, so
 * nothing in memory survives except what a step already wrote down.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  budgetCaps,
  DEFAULT_SETTINGS,
  type Flow,
  type FlowStepRecord,
  type Level,
  type Mode,
  type ParseFlowResult,
  parseFlow,
  type ResolvedSettings,
  type SettingReport,
  type Step,
  resolveSettings,
} from "./contracts.ts";
import { parseHandoff } from "./handoff.ts";

/** The state file's name inside a plan directory. */
export const FLOW_FILE = "FLOW.json";

/**
 * The custom session entry naming the flow a session belongs to. A step session
 * is born with it (through `newSession`'s `setup`), so `/flow next`, `/flow
 * status` and a resumed session all find their plan directory without memory.
 */
export const FLOW_ENTRY = "flow";

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

// ── the plan directory ──────────────────────────────────────────────────────

/**
 * `~/.local/share/agents/<project>/plans/<slug>`, where `<project>` is the main
 * checkout's directory name. `repoMain` comes from `gitRoots(cwd).main`, not
 * `createGitContext`, which names the worktree.
 */
export const planDirFor = (repoMain: string, slug: string): string =>
  join(homedir(), ".local", "share", "agents", basename(repoMain), "plans", slug);

export const flowPath = (planDir: string): string => join(planDir, FLOW_FILE);

/** A file's text, or undefined when it is not there; any other read error is the caller's. */
export const readText = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
};

export type ReadFlow =
  | { kind: "ok"; flow: Flow }
  | { kind: "none" }
  /** A file that exists and does not parse: reported, never overwritten. */
  | { kind: "corrupt"; error: string };

export const readFlow = (planDir: string): ReadFlow => {
  let text: string | undefined;
  try {
    text = readText(flowPath(planDir));
  } catch (error) {
    return { kind: "corrupt", error: message(error) };
  }
  if (text === undefined) return { kind: "none" };
  const parsed: ParseFlowResult = parseFlow(text);
  return parsed.ok ? { kind: "ok", flow: parsed.flow } : { kind: "corrupt", error: parsed.error };
};

/** Writes FLOW.json through a temp file and a rename, so a crash leaves one whole file. */
export const writeFlow = (flow: Flow): void => {
  mkdirSync(flow.planDir, { recursive: true });
  const path = flowPath(flow.planDir);
  const temp = `${path}.${process.pid}.tmp`;
  writeFileSync(temp, `${JSON.stringify(flow, null, 2)}\n`, { mode: 0o600 });
  renameSync(temp, path);
};

/** The custom entry naming this session's flow; the last one wins. */
export const flowEntryOf = (
  ctx: ExtensionContext,
): { planDir: string; slug: string } | undefined => {
  const entries = ctx.sessionManager.getEntries();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry.type !== "custom" || entry.customType !== FLOW_ENTRY) continue;
    const data = entry.data as { planDir?: unknown; slug?: unknown } | undefined;
    if (typeof data?.planDir === "string" && typeof data.slug === "string")
      return { planDir: data.planDir, slug: data.slug };
  }
  return undefined;
};

/** This session's flow, read from its plan directory; `none` when the session is not a flow's. */
export const flowOf = (ctx: ExtensionContext): ReadFlow => {
  const entry = flowEntryOf(ctx);
  return entry ? readFlow(entry.planDir) : { kind: "none" };
};

// ── settings, budget and the steps' records ─────────────────────────────────

/**
 * `DEFAULT_SETTINGS` with the pi leaf's `flow` key and the flow's own overrides
 * on top (D5). Never throws; a bad value keeps the layer below and is reported.
 */
export const settingsOf = (
  leafFlowSetting: unknown,
  flow: Flow,
): { settings: ResolvedSettings; reports: SettingReport[] } =>
  resolveSettings(DEFAULT_SETTINGS, leafFlowSetting, flow.settings);

/** The handoff's `## Budget` caps, or zeros while HANDOFF.md is missing or unparsable (C3). */
export const budgetOf = (planDir: string): { costCap: number; linesCap: number } => {
  const text = readText(join(planDir, "HANDOFF.md"));
  const parsed = text === undefined ? undefined : parseHandoff(text);
  return parsed?.ok ? budgetCaps(parsed.handoff.budget) : { costCap: 0, linesCap: 0 };
};

/**
 * The flow with its current step's record ended and priced. A no-op once the
 * record is closed, so the tool and the command may both close the same step.
 */
export const closeStep = (flow: Flow, at: number, cost: number): Flow => {
  let index = -1;
  for (let cursor = flow.steps.length - 1; cursor >= 0; cursor -= 1) {
    const record = flow.steps[cursor];
    if (record.step === flow.step && record.endedAt === undefined) {
      index = cursor;
      break;
    }
  }
  if (index < 0) return flow;
  const steps = flow.steps.slice();
  steps[index] = { ...steps[index], endedAt: at, cost } satisfies FlowStepRecord;
  return { ...flow, steps };
};

/** The step record a resume goes back to: the last one for the current step. */
export const recordOf = (flow: Flow, step: Step): FlowStepRecord | undefined => {
  for (let index = flow.steps.length - 1; index >= 0; index -= 1) {
    if (flow.steps[index].step === step) return flow.steps[index];
  }
  return undefined;
};

// ── git: the base, the branch and the diff the budget counts ─────────────────

const git = (cwd: string, args: string[]): string | undefined => {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return undefined;
  }
};

/** The base branch a flow's diff is taken against: `origin/HEAD`, else `main`. */
export const defaultBase = (repoMain: string): string => {
  const head = git(repoMain, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]);
  if (head) return head.slice(head.indexOf("/") + 1);
  return "main";
};

/** `<merge-base(base, branch)>`, or undefined while either branch is missing. */
export const mergeBase = (repoMain: string, base: string, branch: string): string | undefined =>
  git(repoMain, ["merge-base", base, branch]) || undefined;

/** Insertions plus deletions in `<merge-base>..<branch>`; 0 while the branch is missing (D15). */
export const diffLines = (repoMain: string, base: string, branch: string): number => {
  const from = mergeBase(repoMain, base, branch);
  if (!from) return 0;
  const shortstat = git(repoMain, ["diff", "--shortstat", `${from}..${branch}`]);
  if (!shortstat) return 0;
  const insertions = /(\d+) insertion/.exec(shortstat)?.[1];
  const deletions = /(\d+) deletion/.exec(shortstat)?.[1];
  return Number(insertions ?? 0) + Number(deletions ?? 0);
};

// ── a new flow ──────────────────────────────────────────────────────────────

export type NewFlow = {
  slug: string;
  planDir: string;
  repoMain: string;
  base: string;
  branch: string;
  /** The current model and level: the brief keeps them (D5). */
  model: string;
  thinking: Level;
  /** The session the brief runs in; absent for an in-memory session. */
  session?: string;
  parentSession?: string;
  at: number;
};

/**
 * What a step asks before the next one starts (D4): the plan suggestion at
 * `brief → plan`, the approval page at `plan → approve`, and a confirmation at
 * `run → guide` only in `gated` mode, where every gate stops the run (D14).
 */
export type Ask = "picker" | "approval" | "confirm" | "none";

export type Transition = { readonly from: Step; readonly to: Step; readonly ask: Ask };

/** The step after `from`, and what the owner is asked first; `done` has none. */
export const transitionOf = (from: Step, mode: Mode): Transition | undefined => {
  switch (from) {
    case "brief":
      return { from, to: "plan", ask: "picker" };
    case "plan":
      return { from, to: "approve", ask: "approval" };
    case "approve":
      return { from, to: "run", ask: "none" };
    case "run":
      return { from, to: "guide", ask: mode === "gated" ? "confirm" : "none" };
    case "guide":
      return { from, to: "done", ask: "none" };
    default:
      return undefined;
  }
};

/** A flow at its brief step, in the session that started it. */
export const newFlow = (init: NewFlow): Flow => ({
  v: 1,
  slug: init.slug,
  planDir: init.planDir,
  repoMain: init.repoMain,
  base: init.base,
  branch: init.branch,
  step: "brief",
  quick: false,
  settings: {},
  steps: init.session
    ? [
        {
          step: "brief",
          session: init.session,
          parentSession: init.parentSession,
          model: init.model,
          thinking: init.thinking,
          startedAt: init.at,
        },
      ]
    : [],
  judge: [],
});
