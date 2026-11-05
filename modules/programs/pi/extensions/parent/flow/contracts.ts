/**
 * What /flow freezes at G0: the state file (C1), the step table and its
 * settings (C2), the tool names and their shapes (C3), the judge's verdicts
 * (C4), the approval result (C5) and the parsed handoff (C6).
 *
 * Pure on purpose — no pi import, no filesystem — so a unit test drives all of
 * it and every other flow module reads one definition.
 */

/** One step of a flow, in the order a flow visits them (D2). */
export const STEPS = ["brief", "plan", "approve", "run", "guide", "done"] as const;
export type Step = (typeof STEPS)[number];

/** When a run stops for the owner (D14). */
export const MODES = ["gated", "deviation", "straight"] as const;
export type Mode = (typeof MODES)[number];

/** pi's thinking levels, as `setThinkingLevel` takes them. */
export const LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
export type Level = (typeof LEVELS)[number];

/** How much an item is worth: flash items go to `builder`, deep ones to `builder-deep` (D8). */
export type Tier = "flash" | "deep";

// ── settings (C2, D5) ───────────────────────────────────────────────────────

/** Every configurable model choice, D5's table row for row. */
export const SETTING_KEYS = [
  "judge",
  "plan",
  "planQuick",
  "run",
  "guide",
  "items",
  "gateReview",
  "finalReview",
  "simplify",
] as const;
export type SettingKey = (typeof SETTING_KEYS)[number];

/**
 * The keys a step's own session runs on: a step is a model, never a role,
 * because the conductor applies it with `setModel` before the kickoff.
 */
export const SESSION_KEYS = ["judge", "plan", "planQuick", "run", "guide"] as const;

/** The keys that name a subagent role, spawned inside a step. */
export const ROLE_KEYS = ["items", "gateReview", "finalReview", "simplify"] as const;

/**
 * A step's target: a model for a session step, a role (or a hand-picked model)
 * for a delegated one. `deep` is the role a `Tier: deep` item gets, which only
 * `items` uses (D8).
 */
export type StepSetting = { model?: string; role?: string; deep?: string; thinking?: Level };

/** Every key resolved, in the order `flow_status` reports them. */
export type ResolvedSettings = Record<SettingKey, StepSetting>;

/**
 * The defaults D5 fixes, from each vendor's guidance for thinking level. The pi
 * leaf may override them through its `flow` settings key, and a flow's
 * `FLOW.json.settings` on top of that; these are the fallbacks a bad value
 * lands on.
 */
export const DEFAULT_SETTINGS: ResolvedSettings = {
  judge: { model: "vm/flash", thinking: "low" },
  plan: { model: "vm/deep", thinking: "high" },
  planQuick: { model: "vm/flash", thinking: "high" },
  run: { model: "vm/flash", thinking: "low" },
  guide: { model: "vm/flash", thinking: "low" },
  items: { role: "builder", deep: "builder-deep", thinking: "high" },
  // The role locks its thinking level, so there is none to set here.
  gateReview: { role: "reviewer" },
  finalReview: { role: "reviewer-deep", thinking: "high" },
  simplify: { role: "builder", thinking: "high" },
};

/** The settings key a step runs on; `brief`, `approve` and `done` keep what they have. */
export const settingKeyFor = (step: Step, quick: boolean): SettingKey | undefined => {
  if (step === "plan") return quick ? "planQuick" : "plan";
  if (step === "run" || step === "guide") return step;
  return undefined;
};

/** What the kickoff message runs once a step's session exists; `approve` and `done` have none. */
export const kickoffFor = (step: Step, planDir: string, quick = false): string | undefined => {
  switch (step) {
    case "brief":
      return `/skill:flow-brief ${planDir}`;
    case "plan":
      return `/skill:flow-plan ${planDir}${quick ? " --quick" : ""}`;
    case "run":
      return `/skill:flow-run ${planDir}`;
    case "guide":
      return `/skill:flow-guide ${planDir}`;
    default:
      return undefined;
  }
};

/** Why one settings field was refused; the value it kept is the one before it. */
export type SettingReport = {
  key: SettingKey;
  field: "model" | "role" | "deep" | "thinking";
  value: unknown;
  reason: string;
};

/** "provider/model", both halves non-empty, as `ctx.modelRegistry.find` splits it. */
export const isModelRef = (value: unknown): value is string => {
  if (typeof value !== "string") return false;
  const slash = value.indexOf("/");
  return slash > 0 && slash < value.length - 1 && !value.startsWith(" ") && !value.endsWith(" ");
};

/**
 * A role name by syntax. Whether a role file of that name exists is the
 * subagents package's registry, which a pure module cannot see: a caller that
 * spawns checks it, and pi-subagents falls back to the parent's model when it
 * does not find one.
 */
const isRoleName = (value: unknown): value is string =>
  typeof value === "string" && /^[a-z][a-z0-9-]*$/.test(value);

export const isLevel = (value: unknown): value is Level =>
  typeof value === "string" && (LEVELS as readonly string[]).includes(value);

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * `DEFAULT_SETTINGS` with the leaf's `flow` setting and then a flow's
 * `FLOW.json.settings` laid over it, field by field.
 *
 * Never throws: an unknown key, a bad model reference, an unknown role name or
 * an unknown thinking level keeps the value from the layer below and adds a
 * report. A step has one target, and the key's kind decides which may carry it:
 * a role on a `SESSION_KEYS` entry is refused, since only the conductor's
 * `setModel` can start a step's session and a role gives it no model; a model on
 * a `ROLE_KEYS` entry is refused for the same reason in reverse, since every
 * consumer spawns that role. Naming a model clears `role` and naming a role
 * clears `model`, so the other field never sits beside it.
 */
export const resolveSettings = (
  defaults: ResolvedSettings,
  leafFlowSetting: unknown,
  flowOverrides: unknown,
): { settings: ResolvedSettings; reports: SettingReport[] } => {
  const settings = structuredClone(defaults) as ResolvedSettings;
  const reports: SettingReport[] = [];
  const apply = (key: SettingKey, raw: unknown) => {
    if (!isObject(raw)) {
      reports.push({ key, field: "model", value: raw, reason: "a step setting is an object" });
      return;
    }
    if ("thinking" in raw) {
      const thinking = raw.thinking;
      if (isLevel(thinking)) settings[key].thinking = thinking;
      else
        reports.push({
          key,
          field: "thinking",
          value: thinking,
          reason: `not one of ${LEVELS.join(", ")}`,
        });
    }
    if ("model" in raw) {
      const model = raw.model;
      if (!isModelRef(model)) {
        reports.push({ key, field: "model", value: model, reason: 'not "provider/model"' });
      } else if ((ROLE_KEYS as readonly string[]).includes(key)) {
        reports.push({
          key,
          field: "model",
          value: model,
          reason: "a step that spawns a subagent runs on a role, not a model",
        });
      } else {
        settings[key].model = model;
        delete settings[key].role;
      }
    }
    if ("role" in raw) {
      const role = raw.role;
      if (!isRoleName(role)) {
        reports.push({ key, field: "role", value: role, reason: "not a role name" });
      } else if ((SESSION_KEYS as readonly string[]).includes(key)) {
        reports.push({
          key,
          field: "role",
          value: role,
          reason: "a step that gets its own session runs on a model, not a role",
        });
      } else {
        settings[key].role = role;
        delete settings[key].model;
      }
    }
    if ("deep" in raw) {
      const deep = raw.deep;
      if (isRoleName(deep)) settings[key].deep = deep;
      else reports.push({ key, field: "deep", value: deep, reason: "not a role name" });
    }
  };
  for (const layer of [leafFlowSetting, flowOverrides]) {
    if (!isObject(layer)) continue;
    for (const [name, raw] of Object.entries(layer)) {
      // An unknown key is a typo, not a setting nothing reads.
      if (!(SETTING_KEYS as readonly string[]).includes(name)) {
        reports.push({
          key: name as SettingKey,
          field: "model",
          value: raw,
          reason: "not a step setting",
        });
        continue;
      }
      apply(name as SettingKey, raw);
    }
  }
  return { settings, reports };
};

// ── the state file (C1) ─────────────────────────────────────────────────────

/** One step's session, and what it cost once its transition closed it. */
export type FlowStepRecord = {
  step: Step;
  /** The session file; the step is unreadable after the next switch. */
  session: string;
  parentSession?: string;
  model: string;
  thinking: Level;
  startedAt: number;
  /** Set only after the step's kickoff was delivered, so resume can retry a lost one. */
  kickoffSent?: boolean;
  /** The note `flow_next` left for this step's owner. */
  note?: string;
  endedAt?: number;
  cost?: number;
};

/** A judge call, kept next to the step cost it suggested (D6). */
export type FlowJudgeRecord = {
  at: "brief" | "handoff";
  verdict: unknown;
  cost: number;
  model: string;
};

/** The tuicr session a flow seeded, and the `/rv` line that reopens it (D24). */
export type FlowTour = { slug: string; argv: string[]; cwd: string; rv: string };

/** The next session's model and level, written before the switch so a crash resumes. */
export type PendingStep = { step: Step; model: string; thinking: Level; kickoff: string };

/** `FLOW.json`: the only state that crosses a session switch. */
export type Flow = {
  v: 1;
  slug: string;
  planDir: string;
  /** The main checkout, where a diff and a tuicr session are taken. */
  repoMain: string;
  base: string;
  branch: string;
  step: Step;
  mode?: Mode;
  quick: boolean;
  /** Per-flow overrides, unresolved: `resolveSettings` validates them. */
  settings: Record<string, unknown>;
  pending?: PendingStep;
  steps: FlowStepRecord[];
  judge: FlowJudgeRecord[];
  tour?: FlowTour;
};

export type ParseFlowResult = { ok: true; flow: Flow } | { ok: false; error: string };

const isNumber = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);

const isText = (value: unknown): value is string => typeof value === "string" && value !== "";

const isStep = (value: unknown): value is Step =>
  typeof value === "string" && (STEPS as readonly string[]).includes(value);

const isMode = (value: unknown): value is Mode =>
  typeof value === "string" && (MODES as readonly string[]).includes(value);

/**
 * `FLOW.json`'s parser: `{ok: true, flow}` or `{ok: false, error}` naming the
 * field that failed. Unknown keys are kept out of the result but do not fail it,
 * so a newer flow's file still opens; `settings` is returned unresolved, since a
 * bad value there falls back instead of refusing the file (C2).
 */
export const parseFlow = (text: string): ParseFlowResult => {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    return { ok: false, error: `not JSON: ${error instanceof Error ? error.message : "?"}` };
  }
  if (!isObject(raw)) return { ok: false, error: "the file holds no JSON object" };
  const fail = (field: string, want: string) => ({
    ok: false as const,
    error: `${field} must be ${want}`,
  });

  if (raw.v !== 1) return fail("v", "1");
  for (const field of ["slug", "planDir", "repoMain", "base", "branch"] as const) {
    if (!isText(raw[field])) return fail(field, "a non-empty string");
  }
  if (!isStep(raw.step)) return fail("step", `one of ${STEPS.join(", ")}`);
  if (raw.mode !== undefined && !isMode(raw.mode))
    return fail("mode", `one of ${MODES.join(", ")}`);
  if (typeof raw.quick !== "boolean") return fail("quick", "a boolean");
  if (raw.settings !== undefined && !isObject(raw.settings)) return fail("settings", "an object");

  let pending: PendingStep | undefined;
  if (raw.pending !== undefined) {
    const p = raw.pending;
    if (!isObject(p)) return fail("pending", "an object");
    if (!isStep(p.step)) return fail("pending.step", `one of ${STEPS.join(", ")}`);
    if (!isText(p.model)) return fail("pending.model", "a non-empty string");
    if (!isLevel(p.thinking)) return fail("pending.thinking", `one of ${LEVELS.join(", ")}`);
    if (typeof p.kickoff !== "string") return fail("pending.kickoff", "a string");
    pending = { step: p.step, model: p.model, thinking: p.thinking, kickoff: p.kickoff };
  }

  if (!Array.isArray(raw.steps)) return fail("steps", "an array");
  const steps: FlowStepRecord[] = [];
  for (const [index, value] of raw.steps.entries()) {
    const at = `steps[${index}]`;
    if (!isObject(value)) return fail(at, "an object");
    if (!isStep(value.step)) return fail(`${at}.step`, `one of ${STEPS.join(", ")}`);
    if (!isText(value.session)) return fail(`${at}.session`, "a non-empty string");
    if (value.parentSession !== undefined && typeof value.parentSession !== "string")
      return fail(`${at}.parentSession`, "a string");
    if (!isText(value.model)) return fail(`${at}.model`, "a non-empty string");
    if (!isLevel(value.thinking)) return fail(`${at}.thinking`, `one of ${LEVELS.join(", ")}`);
    if (!isNumber(value.startedAt)) return fail(`${at}.startedAt`, "a number");
    if (value.kickoffSent !== undefined && typeof value.kickoffSent !== "boolean")
      return fail(`${at}.kickoffSent`, "a boolean");
    if (value.note !== undefined && typeof value.note !== "string")
      return fail(`${at}.note`, "a string");
    if (value.endedAt !== undefined && !isNumber(value.endedAt))
      return fail(`${at}.endedAt`, "a number");
    if (value.cost !== undefined && !isNumber(value.cost)) return fail(`${at}.cost`, "a number");
    steps.push({
      step: value.step,
      session: value.session,
      parentSession: value.parentSession as string | undefined,
      model: value.model,
      thinking: value.thinking,
      startedAt: value.startedAt,
      kickoffSent: value.kickoffSent as boolean | undefined,
      note: value.note as string | undefined,
      endedAt: value.endedAt as number | undefined,
      cost: value.cost as number | undefined,
    });
  }

  if (!Array.isArray(raw.judge)) return fail("judge", "an array");
  const judge: FlowJudgeRecord[] = [];
  for (const [index, value] of raw.judge.entries()) {
    const at = `judge[${index}]`;
    if (!isObject(value)) return fail(at, "an object");
    if (value.at !== "brief" && value.at !== "handoff") return fail(`${at}.at`, "brief or handoff");
    if (value.verdict === undefined) return fail(`${at}.verdict`, "present");
    if (!isNumber(value.cost)) return fail(`${at}.cost`, "a number");
    if (!isText(value.model)) return fail(`${at}.model`, "a non-empty string");
    judge.push({
      at: value.at,
      verdict: value.verdict,
      cost: value.cost,
      model: value.model,
    });
  }

  let tour: FlowTour | undefined;
  if (raw.tour !== undefined) {
    const t = raw.tour;
    if (!isObject(t)) return fail("tour", "an object");
    if (!isText(t.slug)) return fail("tour.slug", "a non-empty string");
    if (!Array.isArray(t.argv) || !t.argv.every((arg) => typeof arg === "string"))
      return fail("tour.argv", "an array of strings");
    if (!isText(t.cwd)) return fail("tour.cwd", "a non-empty string");
    if (!isText(t.rv)) return fail("tour.rv", "a non-empty string");
    tour = { slug: t.slug, argv: t.argv, cwd: t.cwd, rv: t.rv };
  }

  return {
    ok: true,
    flow: {
      v: 1,
      slug: raw.slug as string,
      planDir: raw.planDir as string,
      repoMain: raw.repoMain as string,
      base: raw.base as string,
      branch: raw.branch as string,
      step: raw.step,
      mode: raw.mode,
      quick: raw.quick,
      settings: (raw.settings as Record<string, unknown> | undefined) ?? {},
      pending,
      steps,
      judge,
      tour,
    },
  };
};

/** A flow's mode; before the approval page it is `gated`, the strictest reading. */
export const modeOf = (flow: Flow): Mode => flow.mode ?? "gated";

// ── the tools the skills call (C3) ──────────────────────────────────────────

export const TOOL_NEXT = "flow_next";
export const TOOL_STATUS = "flow_status";
export const TOOL_TOUR = "flow_tour";

/**
 * What `flow_status` answers, and the only way a skill reads `FLOW.json` (C3).
 *
 * A cap of 0 means the handoff set no cap on that axis, so nothing can exceed
 * it; `modeOf` says what an absent mode means before the approval page.
 */
export type FlowBudget = {
  costCap: number;
  spentStep: number;
  spentTotal: number;
  lines: number;
  linesCap: number;
};

export type FlowStatus = {
  slug: string;
  planDir: string;
  /** The main checkout a diff and a tuicr session are taken in. */
  repoMain: string;
  /** The diff a run is measured against: `merge-base(base, branch)..branch`. */
  base: string;
  branch: string;
  step: Step;
  /** Before the approval page there is none; `modeOf` reads that as `gated`. */
  mode?: Mode;
  quick: boolean;
  settings: ResolvedSettings;
  budget: FlowBudget;
};

/** One stop of the review tour: a line of the diff, or the whole review. */
export type TourStop = {
  file?: string;
  line?: number;
  endLine?: number;
  side?: "old" | "new";
  /** A tuicr comment type: issue, suggestion, nit, note or praise. */
  type: string;
  body: string;
};

export type TourSpec = { intro: string; stops: TourStop[] };

// ── the judge (C4, D6) ──────────────────────────────────────────────────────

/** `judgeBrief`'s suggestion for the plan step, with a reason per choice. */
export type JudgeBriefVerdict = {
  plan: "full" | "quick";
  model: string;
  thinking: Level;
  reasons: string[];
  cost: number;
};

/** `judgeHandoff`'s suggestion for the run: mode, run step, item tiers, final reviewer. */
export type JudgeHandoffVerdict = {
  mode: Mode;
  run: { model: string; thinking: Level };
  /** Item ID → tier, for items the judge would move. */
  tiers: Record<string, Tier>;
  /** The role the final gate runs on. */
  finalReview: string;
  reasons: string[];
  cost: number;
};

// ── the approval page (C5, D13) ─────────────────────────────────────────────

/** What the owner chose on the approval page, and the flow it left behind when approving. */
export type Approval =
  | { kind: "approve"; flow: Flow }
  | { kind: "back"; note: string }
  | { kind: "cancel" };

// ── the handoff grammar (C6, D10) ───────────────────────────────────────────

export const ITEM_ID = /^(?:G|A|S)\d+$/;

/** A `- U1 …` or `- D1 …` bullet under `### Yours` / `### Defaults`. */
export type HandoffDecision = { id: string; kind: "yours" | "default"; text: string; line: number };

/** A `- C1 <name>: <shape>. Why: <reason>.` bullet. */
export type HandoffContract = {
  id: string;
  name: string;
  shape: string;
  why: string;
  line: number;
};

/** One `### <ID> <title>` item and its field bullets. */
export type HandoffItem = {
  id: string;
  title: string;
  /** A `(spike, timebox <n>)` title, whose `Why:` line says what it buys. */
  spike: boolean;
  blockedBy: string[];
  /** Paths and globs the item may change; two in flight never overlap. */
  owns: string[];
  /** What it adds: systems, files, abstractions, as the `New:` line reads. */
  adds: string;
  tier: Tier;
  /** The `Tier:` line, 1-based, which the approval page rewrites in place. */
  tierLine: number;
  outcome: string;
  acceptance: string;
  /** An acceptance whose last characters are `(unverified)` needs the owner or a device. */
  acceptanceUnverified: boolean;
  constraints: string;
  why?: string;
  line: number;
};

/** The `## Budget` bullets; all five are required, and C3's caps derive from two of them (D15). */
export type HandoffBudget = {
  newFiles: number;
  newAbstractions: number;
  lines: number;
  costCap: number;
  concurrency: number;
};

/** The caps `flow_status` reports, from a parsed budget: `Lines` × 1.5, and the cost cap as given. */
export const budgetCaps = (budget: HandoffBudget): { costCap: number; linesCap: number } => ({
  costCap: budget.costCap,
  linesCap: Math.round(budget.lines * 1.5),
});

export type HandoffQuestion = { id: string; text: string; line: number };

/** `HANDOFF.md` parsed: the required sections, typed, plus the optional ones raw. */
export type ParsedHandoff = {
  mission: string;
  smallestVersion: string;
  notBuilding: string[];
  scope: string;
  context: string;
  yours: HandoffDecision[];
  defaults: HandoffDecision[];
  uncertain: HandoffDecision[];
  items: HandoffItem[];
  contracts: HandoffContract[];
  budget: HandoffBudget;
  stops: string[];
  openQuestions: HandoffQuestion[];
  amendments: string;
  /**
   * Every `##` section's body keyed by its heading text, required ones
   * included, so the approval page renders whatever the plan wrote.
   */
  sections: Record<string, string>;
};
