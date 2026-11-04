/**
 * The conductor: `/flow`'s command surface (start, status, resume, next), the
 * step transitions with the questions each asks, and the `session_start` that
 * gives a new step session its model, level and kickoff (C1–C5, D2–D4, D14,
 * D18, D26).
 *
 * Everything that talks to the model or the owner is injected, so a unit test
 * walks the whole machine with a fake `newSession` and a fake picker; the
 * feature entry (`../flow.ts`) supplies pi's real ones.
 */
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import { gitRoots } from "../../shared/git.ts";
import {
  type Approval,
  DEFAULT_SETTINGS,
  type Flow,
  type FlowStepRecord,
  type FlowStatus,
  isLevel,
  isModelRef,
  type JudgeBriefVerdict,
  type JudgeHandoffVerdict,
  kickoffFor,
  LEVELS,
  type Level,
  modeOf,
  type ParsedHandoff,
  type ResolvedSettings,
  type SettingReport,
  SETTING_KEYS,
  type Step,
  STEPS,
} from "./contracts.ts";
import { parseHandoff } from "./handoff.ts";
import {
  closeStep,
  defaultBase,
  FLOW_ENTRY,
  flowOf,
  newFlow,
  planDirFor,
  readFlow,
  readText,
  recordOf,
  settingsOf,
  transitionOf,
  writeFlow,
} from "./state.ts";
import { type Runtime, settingsFor, statusOf } from "./tools.ts";

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** A flow's slug is also its branch, so git's ref rules win: no spaces, no `..`, no leading dash. */
const SLUG = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

// ── what the conductor needs from pi ────────────────────────────────────────

/** C4's `judgeBrief`, injected so the conductor's tests need no model. */
export type JudgeBriefFn = (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  brief: string,
  settings: ResolvedSettings,
) => Promise<JudgeBriefVerdict>;

/** C4's `judgeHandoff`. */
export type JudgeHandoffFn = (
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  handoff: ParsedHandoff,
  settings: ResolvedSettings,
) => Promise<JudgeHandoffVerdict>;

/** C5's `approve`. */
export type ApproveFn = (
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  flow: Flow,
  handoff: ParsedHandoff,
  verdict: JudgeHandoffVerdict,
) => Promise<Approval>;

/** Everything a command handler acts through. */
export type Deps = {
  pi: ExtensionAPI;
  ctx: ExtensionCommandContext;
  now: () => number;
  /** Whether a subagent is still working; the switch that follows aborts it (D26). */
  hasRunning: () => boolean;
  /** What a session's transcript has cost so far, in USD. */
  cost: (ctx: ExtensionContext) => number;
  judgeBrief: JudgeBriefFn;
  judgeHandoff: JudgeHandoffFn;
  approve: ApproveFn;
};

/** A `session_start` handler's context has no session control, and needs none. */
export type StartDeps = {
  pi: ExtensionAPI;
  ctx: ExtensionContext;
  now: () => number;
};

// ── the command ─────────────────────────────────────────────────────────────

/**
 * `/flow` in one of its four forms (D3): a bare `/flow` asks for a slug outside
 * a flow and shows the status inside one; `<slug>` starts a flow; `resume`
 * reopens one; `next` advances the current step.
 */
export const command = async (deps: Deps, runtime: Runtime, args: string): Promise<void> => {
  const words = args.trim().split(/\s+/).filter(Boolean);
  const [verb, ...rest] = words;
  const here = flowOf(deps.ctx);

  if (verb === "next") return advance(deps, runtime);
  if (verb === "resume") return resume(deps, here, rest[0]);
  if (verb === "status") return showStatus(deps, here);

  if (verb === undefined) {
    if (here.kind === "ok") return showStatus(deps, here);
    const typed = await deps.ctx.ui.input(
      "Start a flow",
      "kebab-case slug: names the plan directory and the branch",
    );
    const slug = typed?.trim();
    if (!slug) return;
    return start(deps, here, slug);
  }
  return start(deps, here, verb);
};

/** Where the flow is, what it has cost, and what waits on the owner. */
const showStatus = (deps: Deps, here: ReturnType<typeof flowOf>): void => {
  if (here.kind === "none") {
    deps.ctx.ui.notify("No flow in this session: `/flow <slug>` starts one.", "info");
    return;
  }
  if (here.kind === "corrupt") {
    deps.ctx.ui.notify(`flow: ${here.error}. FLOW.json is left as it is.`, "error");
    return;
  }
  const flow = here.flow;
  const status = statusOf(
    { runtime: {}, now: deps.now, hasRunning: deps.hasRunning, cost: deps.cost },
    deps.ctx,
    flow,
    settingsOf(leafOf(deps.pi), flow).settings,
  );
  footer(deps.ctx, flow);
  deps.ctx.ui.notify(statusText(status, flow, readText(`${flow.planDir}/PROGRESS.md`)), "info");
};

/** Starts a flow in this session: FLOW.json, the brief step, then `/skill:flow-brief` (D3). */
const start = async (deps: Deps, here: ReturnType<typeof flowOf>, slug: string): Promise<void> => {
  if (!SLUG.test(slug)) {
    deps.ctx.ui.notify(
      `flow: "${slug}" cannot be a branch name. Use letters, digits, dot, dash or underscore.`,
      "error",
    );
    return;
  }
  if (here.kind === "ok") {
    deps.ctx.ui.notify(
      `This session already runs flow ${here.flow.slug}; /flow next advances it. /flow resume <slug> reopens another.`,
      "info",
    );
    return;
  }
  if (here.kind === "corrupt") {
    deps.ctx.ui.notify(`flow: ${here.error}. FLOW.json is left as it is.`, "error");
    return;
  }
  const roots = gitRoots(deps.ctx.cwd);
  const repoMain = roots.main ?? roots.root;
  if (!repoMain) {
    deps.ctx.ui.notify(`flow needs a git checkout; ${deps.ctx.cwd} is not inside one.`, "error");
    return;
  }
  const planDir = planDirFor(repoMain, slug);
  const existing = readFlow(planDir);
  if (existing.kind === "ok") {
    deps.ctx.ui.notify(
      `flow ${slug} already exists at its ${existing.flow.step} step: /flow resume ${slug} reopens it.`,
      "info",
    );
    return;
  }
  if (existing.kind === "corrupt") {
    deps.ctx.ui.notify(
      `flow ${slug}: ${planDir}/FLOW.json does not parse (${existing.error}).`,
      "error",
    );
    return;
  }
  const model = deps.ctx.model;
  if (!model) {
    deps.ctx.ui.notify("flow: this session has no model yet; pick one with /model first.", "error");
    return;
  }
  const flow = newFlow({
    slug,
    planDir,
    repoMain,
    base: defaultBase(repoMain),
    branch: slug,
    model: `${model.provider}/${model.id}`,
    thinking: (deps.ctx.thinkingLevel ?? deps.pi.getThinkingLevel()) as Level,
    session: deps.ctx.sessionManager.getSessionFile(),
    at: deps.now(),
  });
  const kickoff = kickoffFor("brief", planDir);
  if (!kickoff) {
    deps.ctx.ui.notify("flow: the brief step has no kickoff to send.", "error");
    return;
  }
  writeFlow(flow);
  deps.pi.appendEntry(FLOW_ENTRY, { planDir, slug });
  footer(deps.ctx, flow);
  // The brief keeps this session and this model (D5, U3). A turn the owner
  // started is idle here, so this begins one.
  deps.pi.sendUserMessage(kickoff, { expandPromptTemplates: true });
};

// ── advancing ───────────────────────────────────────────────────────────────

/**
 * `/flow next`: ends the current step and starts the next one, asking what that
 * transition asks first. Refuses while a subagent runs, and while the step's own
 * session is still pending because its model could not be applied.
 */
const advance = async (deps: Deps, runtime: Runtime): Promise<void> => {
  runtime.advancing = undefined;
  const here = flowOf(deps.ctx);
  if (here.kind === "none") {
    deps.ctx.ui.notify("No flow in this session: `/flow <slug>` starts one.", "error");
    return;
  }
  if (here.kind === "corrupt") {
    deps.ctx.ui.notify(`flow: ${here.error}. FLOW.json is left as it is.`, "error");
    return;
  }
  const flow = here.flow;
  if (deps.hasRunning()) {
    deps.ctx.ui.notify(
      "flow: a subagent is still running, and the next step's session switch would abort it. Wait for it, then /flow next.",
      "warning",
    );
    return;
  }
  if (flow.pending && flow.pending.step === flow.step) {
    deps.ctx.ui.notify(
      `flow: the ${flow.step} step never started (${flow.pending.model} could not be applied). /flow resume retries it.`,
      "warning",
    );
    return;
  }
  switch (flow.step) {
    case "brief":
      return briefToPlan(deps, flow);
    case "plan":
    case "approve":
      return planToRun(deps, flow);
    case "run":
      return runToGuide(deps, flow);
    case "guide":
      return guideToDone(deps, flow);
    default:
      deps.ctx.ui.notify(
        `flow ${flow.slug} is done. Its plan directory is ${flow.planDir}.`,
        "info",
      );
  }
};

/** The judge suggests the plan step's settings, the owner confirms or edits them (D4, D6). */
const briefToPlan = async (deps: Deps, flow: Flow): Promise<void> => {
  const brief = readText(`${flow.planDir}/BRIEF.md`);
  if (brief === undefined) {
    deps.ctx.ui.notify(
      `flow: BRIEF.md is not in ${flow.planDir} yet; flow-brief writes it first.`,
      "warning",
    );
    return;
  }
  const { settings, reports } = settingsOf(leafOf(deps.pi), flow);
  report(deps, reports);
  const verdict = await deps.judgeBrief(deps.pi, deps.ctx, brief, settings);
  const judged = judge(flow, "brief", verdict, settings);
  writeFlow(judged);
  const pick = await pickPlanStep(deps, settings, verdict);
  if (!pick) {
    deps.ctx.ui.notify("flow: the plan step was not confirmed; /flow next asks again.", "info");
    return;
  }
  await beginStep(deps, { ...judged, quick: pick.quick }, "plan", pick.model, pick.thinking);
};

/** One pick from the brief → plan picker: full or quick, on which model and level. */
export type PlanPick = { quick: boolean; model: string; thinking: Level };

/**
 * The `brief → plan` picker: the judge's suggestion first, the other plan stage
 * beside it, and an edit path for both fields. The first entry is what Enter
 * takes, so confirming the judge is one key (D4).
 */
export const pickPlanStep = async (
  deps: Deps,
  settings: ResolvedSettings,
  verdict: JudgeBriefVerdict,
): Promise<PlanPick | undefined> => {
  const full: PlanPick = { quick: false, model: verdict.model, thinking: verdict.thinking };
  const quick: PlanPick = {
    quick: true,
    model: settings.planQuick.model ?? DEFAULT_SETTINGS.planQuick.model ?? "",
    thinking: settings.planQuick.thinking ?? DEFAULT_SETTINGS.planQuick.thinking ?? "high",
  };
  const order = verdict.plan === "quick" ? [quick, full] : [full, quick];
  const edit = "edit the model and level…";
  const label = (pick: PlanPick) =>
    `${pick.quick ? "quick" : "full"} — ${pick.model} · ${pick.thinking}`;
  const options = [...order.map(label), edit];
  const reason = verdict.reasons[0] ? ` — ${verdict.reasons[0]}` : "";
  const choice = await deps.ctx.ui.select(
    `Plan step (the judge suggests ${verdict.plan})${reason}`,
    options,
  );
  if (choice === undefined) return undefined;
  if (choice !== edit) {
    const index = options.indexOf(choice);
    return index >= 0 && index < order.length ? order[index] : undefined;
  }
  const model = await deps.ctx.ui.input("Plan model, as provider/model", full.model);
  if (model === undefined) return undefined;
  const thinking = await deps.ctx.ui.select("Plan thinking level", [...LEVELS]);
  if (thinking === undefined) return undefined;
  if (!isModelRef(model) || !isLevel(thinking)) {
    deps.ctx.ui.notify(`flow: "${model}" and "${thinking}" are not a model and a level.`, "error");
    return undefined;
  }
  return { quick: false, model, thinking };
};

/**
 * PARSE BEFORE THE PAGE: the handoff parser's errors refuse the approval and go
 * back to the planner (D10); a parsed one opens the page with the judge's
 * verdict (C4, C5) and, approved, starts the run session.
 */
const planToRun = async (deps: Deps, flow: Flow): Promise<void> => {
  const text = readText(`${flow.planDir}/HANDOFF.md`);
  if (text === undefined) {
    deps.ctx.ui.notify(
      `flow: HANDOFF.md is not in ${flow.planDir} yet; flow-plan writes it first.`,
      "warning",
    );
    return;
  }
  const parsed = parseHandoff(text);
  if (!parsed.ok) {
    const errors = parsed.errors.map((error) => `line ${error.line}: ${error.message}`).join("\n");
    deps.ctx.ui.notify(
      `flow: HANDOFF.md does not parse, so approval is refused.\n${errors}`,
      "error",
    );
    deps.pi.sendUserMessage(
      `HANDOFF.md does not parse, so the approval page did not open. Fix these and call flow_next again:\n${errors}`,
    );
    return;
  }
  const { settings, reports } = settingsOf(leafOf(deps.pi), flow);
  report(deps, reports);
  const verdict = await deps.judgeHandoff(deps.pi, deps.ctx, parsed.handoff, settings);
  const judged = judge(applyVerdict(flow, verdict), "handoff", verdict, settings);
  // The page reads and rewrites FLOW.json (settings, mode) and HANDOFF.md (tiers).
  writeFlow(judged);

  let approval: Approval;
  try {
    approval = await deps.approve(deps.pi, deps.ctx, judged, parsed.handoff, verdict);
  } catch (error) {
    deps.ctx.ui.notify(`flow: the approval page failed: ${message(error)}`, "error");
    return;
  }
  if (approval.kind === "back") {
    deps.ctx.ui.notify(`flow: sent back to the plan step: ${approval.note}`, "info");
    await deps.pi.sendUserMessage(approval.note);
    return;
  }
  if (approval.kind === "cancel") {
    deps.ctx.ui.notify("flow: approval cancelled; the flow stays at its plan step.", "info");
    return;
  }
  const run = settingsFor(leafOf(deps.pi), approval.flow).run;
  await beginStep(
    deps,
    approval.flow,
    "run",
    run.model ?? DEFAULT_SETTINGS.run.model ?? "",
    run.thinking ?? DEFAULT_SETTINGS.run.thinking ?? "low",
  );
};

/** In gated mode every gate stops the run; other modes only stop on a deviation (D14). */
const runToGuide = async (deps: Deps, flow: Flow): Promise<void> => {
  const transition = transitionOf(flow.step, modeOf(flow));
  if (transition?.ask === "confirm") {
    const go = await deps.ctx.ui.confirm(
      "Run finished. Move to the guide?",
      "Gated mode stops at every gate; the guide step writes REVIEW-GUIDE.md and seeds the review tour.",
    );
    if (!go) {
      deps.ctx.ui.notify("flow: staying in the run step.", "info");
      return;
    }
  }
  const guide = settingsFor(leafOf(deps.pi), flow).guide;
  await beginStep(
    deps,
    flow,
    "guide",
    guide.model ?? DEFAULT_SETTINGS.guide.model ?? "",
    guide.thinking ?? DEFAULT_SETTINGS.guide.thinking ?? "low",
  );
};

/** The last step has no session: it ends the flow where the guide left it. */
const guideToDone = async (deps: Deps, flow: Flow): Promise<void> => {
  const done: Flow = {
    ...closeStep(flow, deps.now(), spend(deps)),
    step: "done",
    pending: undefined,
  };
  writeFlow(done);
  deps.ctx.ui.setStatus("flow", undefined);
  deps.ctx.ui.notify(`flow ${done.slug}: done. The plan directory is ${done.planDir}.`, "info");
};

// ── a step's own session ────────────────────────────────────────────────────

/**
 * The step's model and level are applied in the NEW instance's `session_start`
 * (pi offers no other route: `withSession` has no `setModel`, and the captured
 * `pi` is stale). The pending step is written here, before the switch, so a
 * crash resumes instead of losing the step; `session_start` clears it once the
 * model is really on.
 */
const beginStep = async (
  deps: Deps,
  flow: Flow,
  step: Step,
  model: string,
  thinking: Level,
  kickoff?: string,
): Promise<void> => {
  const text = kickoff ?? kickoffFor(step, flow.planDir, flow.quick);
  if (!text) {
    deps.ctx.ui.notify(`flow: the ${step} step has no kickoff to send.`, "error");
    return;
  }
  const next: Flow = {
    ...closeStep(flow, deps.now(), spend(deps)),
    step,
    pending: { step, model, thinking, kickoff: text },
  };
  try {
    writeFlow(next);
  } catch (error) {
    deps.ctx.ui.notify(`flow: could not write FLOW.json: ${message(error)}`, "error");
    return;
  }
  footer(deps.ctx, next);
  const parentSession = deps.ctx.sessionManager.getSessionFile();
  try {
    const result = await deps.ctx.newSession({
      parentSession,
      // The new session is born knowing its flow, so `/flow next`, `/flow status`
      // and a resumed session find FLOW.json without any memory.
      setup: async (manager) => {
        manager.appendCustomEntry(FLOW_ENTRY, { planDir: next.planDir, slug: next.slug });
      },
      withSession: async (replaced) => {
        // A throw in here takes pi down with it (notes/testing.md §3): catch it all.
        try {
          const current = readFlow(next.planDir);
          // Still pending means `session_start` refused the model and said so.
          if (current.kind !== "ok" || current.flow.pending) return;
          await replaced.sendUserMessage(text, { expandPromptTemplates: true });
        } catch (error) {
          replaced.ui.notify(
            `flow: the ${step} kickoff failed: ${message(error)}. /flow resume retries the step.`,
            "error",
          );
        }
      },
    });
    if (result.cancelled)
      deps.ctx.ui.notify(
        `flow: the switch to ${step} was cancelled; /flow resume retries it.`,
        "warning",
      );
  } catch (error) {
    deps.ctx.ui.notify(`flow: could not start the ${step} step: ${message(error)}`, "error");
  }
};

/**
 * `session_start` in a new step session: apply the pending model and level,
 * commit the step's record, and set the footer. A model that does not resolve,
 * or that pi refuses, leaves `pending` in place so `/flow resume` retries, and
 * no kickoff is sent (`withSession` checks for it).
 */
export const sessionStart = async (
  deps: StartDeps,
  runtime: Runtime,
  event: SessionStartEvent,
): Promise<void> => {
  if (event.reason !== "new") return;
  runtime.advancing = undefined;
  try {
    const here = flowOf(deps.ctx);
    if (here.kind !== "ok") return;
    const flow = here.flow;
    const pending = flow.pending;
    if (!pending) {
      footer(deps.ctx, flow);
      return;
    }
    const slash = pending.model.indexOf("/");
    const model =
      slash > 0
        ? deps.ctx.modelRegistry.find(pending.model.slice(0, slash), pending.model.slice(slash + 1))
        : undefined;
    if (!model) {
      deps.ctx.ui.notify(
        `flow: ${pending.model} is not in the catalog, so the ${pending.step} step did not start. /flow resume retries it.`,
        "error",
      );
      return;
    }
    if (!(await deps.pi.setModel(model))) {
      deps.ctx.ui.notify(
        `flow: pi refused ${pending.model} (no auth for that provider?), so the ${pending.step} step did not start. /flow resume retries it.`,
        "error",
      );
      return;
    }
    deps.pi.setThinkingLevel(pending.thinking);
    const record: FlowStepRecord = {
      step: pending.step,
      session: deps.ctx.sessionManager.getSessionFile() ?? "(unsaved)",
      parentSession: event.previousSessionFile ?? lastSession(flow),
      model: `${model.provider}/${model.id}`,
      thinking: deps.pi.getThinkingLevel() as Level,
      startedAt: deps.now(),
    };
    const started: Flow = { ...flow, pending: undefined, steps: [...flow.steps, record] };
    writeFlow(started);
    footer(deps.ctx, started);
  } catch (error) {
    deps.ctx.ui.notify(
      `flow: this session could not be prepared for its step: ${message(error)}`,
      "error",
    );
  }
};

/** The `/flow next` a `flow_next` call asked for, sent once the turn settles (§2). */
export const settled = (
  pi: ExtensionAPI,
  runtime: Runtime,
  aborted: boolean,
  ctx: ExtensionContext,
): void => {
  const request = runtime.request;
  runtime.request = undefined;
  if (!request) return;
  if (aborted) {
    ctx.ui.notify(
      "flow: the turn was aborted, so /flow next did not run. Type it to advance.",
      "warning",
    );
    return;
  }
  // Deferred by pi until agent_settled returns; never with `deliverAs` (it throws).
  pi.sendUserMessage("/flow next", { expandPromptTemplates: true });
};

// ── resume ──────────────────────────────────────────────────────────────────

/**
 * `/flow resume [slug]`: the pending step when its session was never created,
 * otherwise the recorded session of the current step (C1).
 */
const resume = async (
  deps: Deps,
  here: ReturnType<typeof flowOf>,
  slug?: string,
): Promise<void> => {
  let flow: Flow | undefined;
  if (slug) {
    const roots = gitRoots(deps.ctx.cwd);
    const repoMain = roots.main ?? roots.root;
    if (!repoMain) {
      deps.ctx.ui.notify(`flow needs a git checkout; ${deps.ctx.cwd} is not inside one.`, "error");
      return;
    }
    const read = readFlow(planDirFor(repoMain, slug));
    if (read.kind === "none") {
      deps.ctx.ui.notify(`flow: no flow ${slug} under ${repoMain}.`, "info");
      return;
    }
    if (read.kind === "corrupt") {
      deps.ctx.ui.notify(`flow ${slug}: ${read.error}. FLOW.json is left as it is.`, "error");
      return;
    }
    flow = read.flow;
  } else if (here.kind === "ok") {
    flow = here.flow;
  } else {
    deps.ctx.ui.notify("Which flow? `/flow resume <slug>`.", "info");
    return;
  }

  if (flow.pending) {
    deps.pi.appendEntry(FLOW_ENTRY, { planDir: flow.planDir, slug: flow.slug });
    deps.ctx.ui.notify(`flow ${flow.slug}: retrying the ${flow.pending.step} step.`, "info");
    await beginStep(
      deps,
      flow,
      flow.pending.step,
      flow.pending.model,
      flow.pending.thinking,
      flow.pending.kickoff,
    );
    return;
  }
  const record = recordOf(flow, flow.step);
  if (!record) {
    deps.ctx.ui.notify(
      `flow ${flow.slug} is at its ${flow.step} step, which has no session of its own. /flow next advances it.`,
      "info",
    );
    return;
  }
  if (record.session === deps.ctx.sessionManager.getSessionFile()) {
    deps.ctx.ui.notify(`This is already the ${flow.step} step. /flow next advances it.`, "info");
    return;
  }
  footer(deps.ctx, flow);
  try {
    await deps.ctx.switchSession(record.session, {
      withSession: async (replaced) => {
        replaced.ui.notify(`flow ${flow?.slug}: resumed the ${flow?.step} step.`, "info");
      },
    });
  } catch (error) {
    deps.ctx.ui.notify(`flow: could not reopen ${record.session}: ${message(error)}`, "error");
  }
};

// ── the status the owner reads ──────────────────────────────────────────────

/** `/flow`'s status: the steps and their sessions, the settings, the budget, and what waits (D3). */
export const statusText = (status: FlowStatus, flow: Flow, progress?: string): string => {
  const lines = [
    `flow ${status.slug} · ${status.step} · ${status.mode ?? "gated"} mode · ${status.quick ? "quick" : "full"} plan`,
    `spend $${status.budget.spentTotal.toFixed(4)} of $${status.budget.costCap.toFixed(2)} · ${status.budget.lines}/${status.budget.linesCap} lines`,
    `base ${status.base} · branch ${status.branch} · ${status.planDir}`,
  ];
  for (const step of STEPS) {
    const record = recordOf(flow, step);
    if (record) {
      const cost = record.cost === undefined ? "open" : `$${record.cost.toFixed(4)}`;
      lines.push(`  ${step}: ${record.session} (${record.model} · ${record.thinking}) ${cost}`);
    } else if (step === status.step) {
      lines.push(`  ${step}: this session`);
    } else {
      lines.push(`  ${step}: —`);
    }
  }
  lines.push(
    `settings: ${SETTING_KEYS.map((key) => `${key} ${describe(status.settings[key])}`).join(", ")}`,
  );
  const blocked = blockedOn(progress);
  if (blocked) lines.push("", blocked);
  return lines.join("\n");
};

const describe = (setting: {
  model?: string;
  role?: string;
  deep?: string;
  thinking?: Level;
}): string => {
  const target =
    setting.model ?? (setting.deep ? `${setting.role} (+${setting.deep})` : setting.role) ?? "?";
  return setting.thinking ? `${target}·${setting.thinking}` : target;
};

/** PROGRESS.md's "Blocked on you" section, verbatim, or undefined when it has none (D3). */
export const blockedOn = (progress: string | undefined): string | undefined => {
  if (!progress) return undefined;
  const lines = progress.split("\n");
  const start = lines.findIndex((line) => /^#{1,6}\s+.*blocked on you/i.test(line));
  if (start < 0) return undefined;
  const body = [lines[start]];
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^#{1,6}\s/.test(lines[index])) break;
    body.push(lines[index]);
  }
  return body.join("\n").trimEnd();
};

// ── small shared pieces ─────────────────────────────────────────────────────

/** The footer segment: `flow <slug> · <step> · $<total>` (D18). */
export const footer = (ctx: ExtensionContext, flow: Flow): void => {
  if (flow.step === "done") {
    ctx.ui.setStatus("flow", undefined);
    return;
  }
  ctx.ui.setStatus("flow", `flow ${flow.slug} · ${flow.step} · $${recordedCost(flow).toFixed(4)}`);
};

/** The leaf's `flow` settings key; read inside a handler, never at load (pi throws there). */
const leafOf = (pi: ExtensionAPI): unknown =>
  (pi.getSettings() as { flow?: unknown } | undefined)?.flow;

const lastSession = (flow: Flow): string | undefined => flow.steps[flow.steps.length - 1]?.session;

const spend = (deps: Deps): number => {
  try {
    return deps.cost(deps.ctx);
  } catch {
    return 0;
  }
};

const recordedCost = (flow: Flow): number =>
  flow.steps.reduce((sum, record) => sum + (record.cost ?? 0), 0) +
  flow.judge.reduce((sum, entry) => sum + entry.cost, 0);

/** The judge's verdict, with its cost, kept next to the step's own (D6). */
const judge = (
  flow: Flow,
  at: "brief" | "handoff",
  verdict: JudgeBriefVerdict | JudgeHandoffVerdict,
  settings: ResolvedSettings,
): Flow => ({
  ...flow,
  judge: [
    ...flow.judge,
    { at, verdict, cost: verdict.cost, model: settings.judge.model ?? settings.judge.role ?? "?" },
  ],
});

/**
 * The judge's suggestions as the page's defaults: the run step's model and
 * level, and the mode, unless the owner already chose them. The owner's own
 * values in `FLOW.json.settings` win.
 */
const applyVerdict = (flow: Flow, verdict: JudgeHandoffVerdict): Flow => {
  const layer: Record<string, unknown> =
    typeof flow.settings === "object" && flow.settings !== null ? flow.settings : {};
  const run = typeof layer.run === "object" && layer.run !== null ? layer.run : {};
  return {
    ...flow,
    mode: flow.mode ?? verdict.mode,
    settings: {
      ...layer,
      run: { model: verdict.run.model, thinking: verdict.run.thinking, ...run },
    },
  };
};

/** An invalid settings value falls back to the layer below and is reported, never thrown (C2). */
const report = (deps: Deps, reports: SettingReport[]): void => {
  if (reports.length === 0) return;
  const lines = reports.map(
    (entry) => `${entry.key}.${entry.field} = ${JSON.stringify(entry.value)}: ${entry.reason}`,
  );
  deps.ctx.ui.notify(
    `flow: ${reports.length} setting${reports.length === 1 ? "" : "s"} refused, the defaults stand:\n${lines.join("\n")}`,
    "warning",
  );
};
