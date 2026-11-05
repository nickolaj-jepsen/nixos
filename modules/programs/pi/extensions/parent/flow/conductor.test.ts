/**
 * A1's conductor tests: the whole machine with a fake `newSession`, a fake
 * picker and a fake judge — what each transition writes and asks, that
 * FLOW.json holds the ended step and the pending step before the switch, that a
 * failed model or a throwing kickoff is reported instead of killing pi, and that
 * a corrupt FLOW.json is never overwritten.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  blockedOn,
  command,
  type Deps,
  pickPlanStep,
  sessionStart,
  settled,
  statusText,
  validSlug,
} from "./conductor.ts";
import {
  DEFAULT_SETTINGS,
  type Flow,
  type JudgeBriefVerdict,
  type ResolvedSettings,
} from "./contracts.ts";
import { parseHandoff } from "./handoff.ts";
import { flowPath, newFlow, readFlow, writeFlow } from "./state.ts";
import { createRuntime, nextTool, type Runtime, statusOf } from "./tools.ts";

type Note = { text: string; kind?: "info" | "warning" | "error" };
type Model = { provider: string; id: string };

type Options = {
  flow?: Partial<Flow>;
  select?: string[];
  input?: string[];
  confirm?: boolean;
  /** The models `modelRegistry.find` resolves; everything else is undefined. */
  registry?: Record<string, Model | undefined>;
  setModel?: boolean;
  hasRunning?: boolean;
  cost?: number;
  kickoffThrows?: boolean;
  /** `pi.sendUserMessage` throws, as the same-session send does on a dead provider. */
  piSendThrows?: boolean;
  /** The session is streaming, so a send from it cannot be trusted to have run. */
  streaming?: boolean;
  judgeBrief?: Deps["judgeBrief"];
  judgeHandoff?: Deps["judgeHandoff"];
  approve?: Deps["approve"];
};

const example = readFileSync(new URL("./handoff-example.md", import.meta.url), "utf8");

const harness = (options: Options = {}) => {
  const dir = mkdtempSync(join(tmpdir(), "flow-conductor-"));
  const flow: Flow = {
    ...newFlow({
      slug: "demo",
      planDir: dir,
      repoMain: dir,
      base: "main",
      branch: "demo",
      model: "fixture/replay",
      thinking: "low",
      session: join(dir, "s0.jsonl"),
      at: 1_000,
    }),
    ...options.flow,
  };
  writeFlow(flow);

  const runtime: Runtime = createRuntime();
  const now = () => 2_000;
  const notes: Note[] = [];
  const statuses: (string | undefined)[] = [];
  const sent: { text: string; expand?: boolean }[] = [];
  const atNewSession: Flow[] = [];
  const switches: string[] = [];
  const models: string[] = [];
  const levels: string[] = [];
  const selections: string[][] = [];
  const inputs: string[] = [];
  const confirms: string[] = [];
  let sessionFile = flow.steps[0]?.session ?? join(dir, "s0.jsonl");
  let level = "low";
  let spawned = 0;
  let kickoffThrows = options.kickoffThrows ?? false;
  let piSendThrows = options.piSendThrows ?? false;
  let streaming = options.streaming ?? false;
  /** What escaped a `withSession`: in pi that is `handleFatalRuntimeError`, which exits. */
  const fatal: unknown[] = [];
  const answers = [...(options.select ?? [])];
  const typed = [...(options.input ?? [])];

  const ui = () => ({
    notify: (text: string, kind?: Note["kind"]) => notes.push({ text, kind }),
    setStatus: (_key: string, text: string | undefined) => statuses.push(text),
    // No scripted answer means Enter: the first entry, which is the judge's pick.
    select: async (title: string, list: string[]) => {
      selections.push([title, ...list]);
      return answers.length > 0 ? answers.shift() : list[0];
    },
    confirm: async (title: string) => {
      confirms.push(title);
      return options.confirm ?? true;
    },
    input: async () => typed.shift(),
  });

  const manager = (file: string, entry?: { planDir: string; slug: string }) => ({
    getEntries: () =>
      entry
        ? [
            {
              type: "custom",
              customType: "flow",
              data: entry,
              id: "entry",
              parentId: null,
              timestamp: "",
            },
          ]
        : [],
    getSessionFile: () => file,
    getSessionId: () => "sid",
    getSessionDir: () => dir,
  });

  const context = (
    file: string,
    entry?: { planDir: string; slug: string },
  ): ExtensionCommandContext =>
    ({
      ui: ui(),
      mode: "tui",
      hasUI: true,
      cwd: dir,
      sessionManager: manager(file, entry),
      modelRegistry: {
        // Without a registry, every model ref resolves: only a test that names
        // models is saying which ones are missing.
        find: (provider: string, id: string) =>
          options.registry === undefined ? { provider, id } : options.registry[`${provider}/${id}`],
      },
      model: { provider: "fixture", id: "replay" },
      thinkingLevel: level,
      isIdle: () => !streaming,
      waitForIdle: async () => {},
      switchSession: async (
        path: string,
        init?: { withSession?: (ctx: unknown) => Promise<void> },
      ) => {
        switches.push(path);
        sessionFile = path;
        try {
          if (init?.withSession)
            await init.withSession(toolContext(context(path, { planDir: dir, slug: flow.slug })));
        } catch (error) {
          fatal.push(error);
        }
        return { cancelled: false };
      },
      newSession: async (init?: {
        parentSession?: string;
        setup?: (m: { appendCustomEntry: (type: string, data: unknown) => void }) => Promise<void>;
        withSession?: (ctx: unknown) => Promise<void>;
      }) => {
        const captured = readFlow(dir);
        if (captured.kind === "ok") atNewSession.push(captured.flow);
        let entry: { planDir: string; slug: string } | undefined;
        await init?.setup?.({
          appendCustomEntry: (_type: string, data: unknown) => {
            entry = data as { planDir: string; slug: string };
          },
        });
        spawned += 1;
        sessionFile = join(dir, `s${spawned}.jsonl`);
        const next = context(sessionFile, entry);
        // pi's order for a replacement: setup → session_start → withSession.
        await sessionStart({ pi, ctx: next, now }, runtime, {
          type: "session_start",
          reason: "new",
          previousSessionFile: flow.steps[0]?.session,
        });
        try {
          if (init?.withSession) await init.withSession(toolContext(next));
        } catch (error) {
          fatal.push(error);
        }
        return { cancelled: false };
      },
    }) as unknown as ExtensionCommandContext;

  const toolContext = (ctx: ExtensionCommandContext): ExtensionContext => {
    const base = ctx as unknown as ExtensionContext & {
      sendUserMessage?: (text: string, opts?: { expandPromptTemplates?: boolean }) => Promise<void>;
    };
    base.sendUserMessage = async (text: string, opts?: { expandPromptTemplates?: boolean }) => {
      if (kickoffThrows) throw new Error("the provider is gone");
      sent.push({ text, expand: opts?.expandPromptTemplates });
    };
    return base;
  };

  const pi = {
    getSettings: () => ({}),
    appendEntry: () => "entry",
    sendUserMessage: (text: string, opts?: { expandPromptTemplates?: boolean }) => {
      if (piSendThrows) throw new Error("the provider is gone");
      sent.push({ text, expand: opts?.expandPromptTemplates });
    },
    setModel: async (model: Model) => {
      models.push(`${model.provider}/${model.id}`);
      return options.setModel ?? true;
    },
    setThinkingLevel: (next: string) => {
      level = next;
      levels.push(next);
    },
    getThinkingLevel: () => level,
  } as unknown as ExtensionAPI;

  const ctx = context(sessionFile, { planDir: dir, slug: flow.slug });
  const deps: Deps = {
    pi,
    ctx,
    now,
    hasRunning: () => options.hasRunning ?? false,
    cost: () => options.cost ?? 0.25,
    judgeBrief:
      options.judgeBrief ??
      (async () => ({
        plan: "full",
        model: "fixture/deep",
        thinking: "high",
        reasons: ["a small brief needs the deep planner"],
        cost: 0.01,
      })),
    judgeHandoff:
      options.judgeHandoff ??
      (async () => ({
        mode: "gated",
        run: { model: "fixture/replay", thinking: "low" },
        tiers: {},
        finalReview: "reviewer-deep",
        reasons: ["gated, because the plan is long"],
        cost: 0.02,
      })),
    approve:
      options.approve ??
      (async (_pi, _ctx, approved: Flow) => ({ kind: "approve", flow: approved })),
  };

  return {
    dir,
    flow,
    runtime,
    pi,
    ctx,
    deps,
    notes,
    statuses,
    sent,
    atNewSession,
    switches,
    models,
    levels,
    selections,
    inputs,
    confirms,
    fatal,
    setKickoffThrows: (value: boolean) => {
      kickoffThrows = value;
    },
    setPiSendThrows: (value: boolean) => {
      piSendThrows = value;
    },
    setStreaming: (value: boolean) => {
      streaming = value;
    },
    read: () => {
      const read = readFlow(dir);
      assert.equal(read.kind, "ok", "FLOW.json should parse");
      return read.kind === "ok" ? read.flow : flow;
    },
    brief: (text = "# Brief\n\nOne page of scope.\n") => writeFileSync(join(dir, "BRIEF.md"), text),
    handoff: (text = example) => writeFileSync(join(dir, "HANDOFF.md"), text),
  };
};

test("/flow next in the brief writes the ended step and the pending one before the switch", async () => {
  const run = harness();
  run.brief();
  await command(run.deps, run.runtime, "next");

  assert.equal(run.atNewSession.length, 1);
  const atSwitch = run.atNewSession[0];
  assert.equal(atSwitch.steps[0].step, "brief");
  assert.equal(atSwitch.steps[0].endedAt, 2_000);
  assert.equal(atSwitch.steps[0].cost, 0.25);
  assert.equal(atSwitch.step, "plan");
  assert.deepEqual(atSwitch.pending, {
    step: "plan",
    model: "fixture/deep",
    thinking: "high",
    kickoff: `/skill:flow-plan ${run.dir}`,
  });
  assert.equal(atSwitch.judge.length, 1);
  assert.equal(atSwitch.judge[0].at, "brief");
  assert.equal(atSwitch.judge[0].cost, 0.01);

  // The picker showed the judge's suggestion first, so Enter confirms it.
  assert.equal(run.selections.length, 1);
  assert.match(run.selections[0][0], /judge suggests full/);
  assert.match(run.selections[0][1], /^full — fixture\/deep · high$/);

  // session_start applied the model and level, committed the record, and the
  // kickoff went to the new session with skill expansion on.
  assert.deepEqual(run.models, ["fixture/deep"]);
  assert.deepEqual(run.levels, ["high"]);
  assert.deepEqual(run.sent, [{ text: `/skill:flow-plan ${run.dir}`, expand: true }]);
  const after = run.read();
  assert.equal(after.pending, undefined);
  assert.equal(after.steps.length, 2);
  assert.equal(after.steps[1].step, "plan");
  assert.equal(after.steps[1].model, "fixture/deep");
  assert.equal(after.steps[1].thinking, "high");
  assert.equal(after.steps[1].session, join(run.dir, "s1.jsonl"));
  assert.equal(after.steps[1].parentSession, join(run.dir, "s0.jsonl"));
  assert.equal(after.steps[1].kickoffSent, true);
  // The judge's $0.01 is in the brief's ledger, so the brief's $0.25 already holds it.
  assert.equal(run.statuses.at(-1), "flow demo · plan · $0.2500");
});

test("the picker offers quick beside the suggestion and edits both fields", async () => {
  const run = harness({
    flow: { settings: { planQuick: { model: "fixture/replay", thinking: "medium" } } },
  });
  const verdict: JudgeBriefVerdict = {
    plan: "full",
    model: "fixture/deep",
    thinking: "high",
    reasons: ["deep"],
    cost: 0,
  };
  const settings: ResolvedSettings = {
    ...DEFAULT_SETTINGS,
    planQuick: { model: "fixture/replay", thinking: "medium" },
  };
  const ui = run.deps.ctx.ui as unknown as {
    select: (title: string, list: string[]) => Promise<string | undefined>;
    input: (title: string, placeholder?: string) => Promise<string | undefined>;
  };
  let offered: string[] = [];
  ui.select = async (_title: string, list: string[]) => {
    offered = list;
    return list[1];
  };
  assert.deepEqual(await pickPlanStep(run.deps, settings, verdict), {
    quick: true,
    model: "fixture/replay",
    thinking: "medium",
  });
  assert.equal(offered.length, 3);
  assert.match(offered[0], /^full — fixture\/deep · high$/);
  assert.match(offered[1], /^quick — fixture\/replay · medium$/);
  assert.match(offered[2], /edit the model and level/);

  // The edit path takes a typed model and a chosen level.
  ui.input = async () => "fixture/x";
  ui.select = async (_title: string, list: string[]) =>
    list.find((entry) => entry.startsWith("edit")) ?? "medium";
  assert.deepEqual(await pickPlanStep(run.deps, settings, verdict), {
    quick: false,
    model: "fixture/x",
    thinking: "medium",
  });

  // A model that is not provider/model is refused.
  ui.input = async () => "nope";
  ui.select = async (_title: string, list: string[]) =>
    list.find((entry) => entry.startsWith("edit")) ?? "medium";
  assert.equal(await pickPlanStep(run.deps, DEFAULT_SETTINGS, verdict), undefined);
  assert.match(run.notes.at(-1)?.text ?? "", /not a model and a level/);
});

test("the judged stage takes the verdict and the other stage its own settings row", async () => {
  const run = harness();
  const ui = run.deps.ctx.ui as unknown as {
    select: (title: string, list: string[]) => Promise<string | undefined>;
  };
  const offered: string[][] = [];
  const settings: ResolvedSettings = {
    ...DEFAULT_SETTINGS,
    plan: { model: "fixture/planner", thinking: "xhigh" },
    planQuick: { model: "fixture/quick", thinking: "medium" },
  };
  const pickBoth = async (verdict: JudgeBriefVerdict) => {
    const picks = [];
    for (const index of [0, 1]) {
      ui.select = async (_title, list) => {
        offered.push(list);
        return list[index];
      };
      picks.push(await pickPlanStep(run.deps, settings, verdict));
    }
    return picks;
  };

  // A quick verdict on a non-default model: quick is the verdict, full is `plan`.
  const quick = await pickBoth({
    plan: "quick",
    model: "fixture/special",
    thinking: "max",
    reasons: ["plan: one file"],
    cost: 0,
  });
  assert.deepEqual(quick, [
    { quick: true, model: "fixture/special", thinking: "max" },
    { quick: false, model: "fixture/planner", thinking: "xhigh" },
  ]);
  assert.deepEqual(offered[0]?.slice(0, 2), [
    "quick — fixture/special · max",
    "full — fixture/planner · xhigh",
  ]);

  // A full verdict: full is the verdict, quick is `planQuick`.
  const full = await pickBoth({
    plan: "full",
    model: "fixture/special",
    thinking: "max",
    reasons: ["plan: many items"],
    cost: 0,
  });
  assert.deepEqual(full, [
    { quick: false, model: "fixture/special", thinking: "max" },
    { quick: true, model: "fixture/quick", thinking: "medium" },
  ]);
});

test("an invalid settings value falls back to the default and is reported", async () => {
  const run = harness({ flow: { settings: { plan: { thinking: "extreme" } } } });
  run.brief();
  await command(run.deps, run.runtime, "next");
  const warning = run.notes.find((note) => note.kind === "warning");
  assert.match(warning?.text ?? "", /setting.*refused/);
  assert.match(warning?.text ?? "", /plan\.thinking/);
  assert.equal(run.atNewSession[0].pending?.thinking, "high");
});

test("/flow next at the plan calls the judge, then the page, and starts the run", async () => {
  const run = harness({ flow: { step: "plan" } });
  run.handoff();
  await command(run.deps, run.runtime, "next");

  const atSwitch = run.atNewSession[0];
  assert.equal(atSwitch.step, "run");
  assert.deepEqual(atSwitch.pending, {
    step: "run",
    model: "fixture/replay",
    thinking: "low",
    kickoff: `/skill:flow-run ${run.dir}`,
  });
  // The judge's mode and run model are the defaults the page opens with.
  assert.equal(atSwitch.mode, "gated");
  assert.deepEqual(atSwitch.settings.run, { model: "fixture/replay", thinking: "low" });
  assert.deepEqual(
    atSwitch.judge.map((entry) => entry.at),
    ["handoff"],
  );
  assert.equal(atSwitch.judge[0].cost, 0.02);
});

test("a changed final reviewer reaches the page but FLOW.json only on approval", async () => {
  let atPage: Flow | undefined;
  const run = harness({
    flow: { step: "plan" },
    judgeHandoff: async () => ({
      mode: "gated",
      run: { model: "fixture/replay", thinking: "low" },
      tiers: {},
      finalReview: "reviewer",
      reasons: ["finalReview: one flash pass is enough"],
      cost: 0,
    }),
    approve: async (_pi, _ctx, flow) => {
      atPage = flow;
      return { kind: "cancel" };
    },
  });
  run.handoff();
  await command(run.deps, run.runtime, "next");
  assert.deepEqual(atPage?.settings.finalReview, { role: "reviewer" });
  assert.equal(run.read().settings.finalReview, undefined);
  assert.equal(run.read().mode, undefined);
  assert.equal(run.read().judge.length, 1);
});

test("after a send-back the next page opens on the next judge's suggestions", async () => {
  const pages: Flow[] = [];
  const verdicts = ["fixture/first", "fixture/second"];
  const run = harness({
    flow: { step: "plan" },
    judgeHandoff: async () => ({
      mode: "deviation",
      run: { model: verdicts.shift() ?? "fixture/none", thinking: "low" },
      tiers: {},
      finalReview: pages.length === 0 ? "reviewer" : "reviewer-deep",
      reasons: ["run: as the plan reads"],
      cost: 0,
    }),
    approve: async (_pi, _ctx, flow) => {
      pages.push(flow);
      return { kind: "back", note: "split A1" };
    },
  });
  run.handoff();
  await command(run.deps, run.runtime, "next");
  await command(run.deps, run.runtime, "next");
  assert.deepEqual(
    pages.map((page) => (page.settings.run as { model?: string }).model),
    ["fixture/first", "fixture/second"],
  );
  assert.deepEqual(pages[0].settings.finalReview, { role: "reviewer" });
  assert.equal(pages[1].settings.finalReview, undefined);
});

test("a handoff that does not parse is refused and goes back to the planner", async () => {
  const run = harness({
    flow: { step: "plan" },
    // A2's parser will refuse this; G0's stub accepts everything, so the test
    // stands on the notes only when the parser has something to say.
  });
  run.handoff("## Mission\n\nnothing else\n");
  await command(run.deps, run.runtime, "next");
  const parsed = parseHandoff(readFileSync(join(run.dir, "HANDOFF.md"), "utf8"));
  if (parsed.ok) {
    assert.equal(run.atNewSession.length, 1, "a parsed handoff goes on to the page");
    return;
  }
  assert.equal(run.atNewSession.length, 0);
  assert.match(run.notes.at(-1)?.text ?? "", /does not parse/);
  assert.match(run.sent.at(-1)?.text ?? "", /Fix these/);
});

test("approval send-back sends its note and keeps the plan's spend live", async () => {
  const run = harness({
    flow: {
      step: "plan",
      steps: [
        {
          step: "brief",
          session: "/s/brief.jsonl",
          model: "m/1",
          thinking: "low",
          startedAt: 1,
          endedAt: 2,
          cost: 0.5,
        },
        {
          step: "plan",
          session: join("/tmp", "plan.jsonl"),
          model: "m/2",
          thinking: "high",
          startedAt: 3,
        },
      ],
    },
    approve: async () => ({ kind: "back", note: "split item A3" }),
  });
  run.handoff();
  nextTool(
    {
      runtime: run.runtime,
      now: run.deps.now,
      hasRunning: run.deps.hasRunning,
      cost: run.deps.cost,
    },
    run.ctx,
  );
  await command(run.deps, run.runtime, "next");
  assert.equal(run.atNewSession.length, 0);
  assert.deepEqual(run.sent, [{ text: "split item A3", expand: undefined }]);
  const plan = run.read().steps.at(-1);
  assert.equal(plan?.endedAt, undefined);
  assert.equal(plan?.cost, undefined);
  const status = statusOf(
    { runtime: run.runtime, now: run.deps.now, hasRunning: run.deps.hasRunning, cost: () => 0.75 },
    run.ctx,
    run.read(),
    DEFAULT_SETTINGS,
  );
  assert.equal(status.budget.spentStep, 0.75);
  // The judge's $0.02 is in the plan's live ledger, not added on top.
  assert.equal(status.budget.spentTotal, 1.25);
});

test("declining the guide keeps the run open and counts the following turn", async () => {
  const stay = harness({
    flow: {
      step: "run",
      steps: [
        {
          step: "run",
          session: "/s/run.jsonl",
          model: "m/1",
          thinking: "low",
          startedAt: 1,
        },
      ],
    },
    confirm: false,
  });
  nextTool(
    {
      runtime: stay.runtime,
      now: stay.deps.now,
      hasRunning: stay.deps.hasRunning,
      cost: stay.deps.cost,
    },
    stay.ctx,
  );
  await command(stay.deps, stay.runtime, "next");
  assert.equal(stay.confirms.length, 1);
  assert.equal(stay.atNewSession.length, 0);
  const flow = stay.read();
  assert.equal(flow.step, "run");
  assert.equal(flow.steps[0]?.endedAt, undefined);
  assert.equal(flow.steps[0]?.cost, undefined);
  const status = statusOf(
    {
      runtime: stay.runtime,
      now: stay.deps.now,
      hasRunning: stay.deps.hasRunning,
      cost: () => 0.75,
    },
    stay.ctx,
    flow,
    DEFAULT_SETTINGS,
  );
  assert.equal(status.budget.spentStep, 0.75);
  assert.equal(status.budget.spentTotal, 0.75);
});

test("gated mode asks before the guide, other modes do not", async () => {
  const straight = harness({ flow: { step: "run", mode: "straight" } });
  await command(straight.deps, straight.runtime, "next");
  assert.equal(straight.confirms.length, 0);
  assert.equal(straight.atNewSession[0].step, "guide");
  assert.equal(straight.atNewSession[0].pending?.thinking, "low");
});

test("guide to done ends the flow and clears the footer", async () => {
  const run = harness({
    flow: {
      step: "guide",
      steps: [
        {
          step: "brief",
          session: "/s/brief.jsonl",
          model: "m/1",
          thinking: "low",
          startedAt: 1,
          endedAt: 2,
          cost: 1,
        },
        { step: "guide", session: "/s/guide.jsonl", model: "m/1", thinking: "low", startedAt: 3 },
      ],
    },
  });
  await command(run.deps, run.runtime, "next");
  const flow = run.read();
  assert.equal(flow.step, "done");
  assert.equal(flow.steps.at(-1)?.endedAt, 2_000);
  assert.equal(flow.steps.at(-1)?.cost, 0.25);
  assert.equal(run.atNewSession.length, 0);
  assert.equal(run.statuses.at(-1), undefined);
});

test("a model that does not resolve leaves the step pending and sends no kickoff", async () => {
  const run = harness({ registry: {} });
  run.brief();
  await command(run.deps, run.runtime, "next");
  assert.deepEqual(run.models, []);
  assert.deepEqual(run.sent, []);
  assert.match(run.notes.at(-1)?.text ?? "", /is not in the catalog/);
  const flow = run.read();
  assert.equal(flow.pending?.step, "plan");
  assert.equal(flow.steps.length, 1);
});

test("a model pi refuses keeps the step pending, with an error", async () => {
  const run = harness({
    registry: { "fixture/deep": { provider: "fixture", id: "deep" } },
    setModel: false,
  });
  run.brief();
  await command(run.deps, run.runtime, "next");
  assert.deepEqual(run.models, ["fixture/deep"]);
  assert.deepEqual(run.sent, []);
  assert.match(run.notes.at(-1)?.text ?? "", /pi refused fixture\/deep/);
  assert.equal(run.read().pending?.step, "plan");
});

test("a throwing kickoff is caught, then resume delivers it", async () => {
  const run = harness({
    registry: { "fixture/deep": { provider: "fixture", id: "deep" } },
    kickoffThrows: true,
  });
  run.brief();
  await assert.doesNotReject(command(run.deps, run.runtime, "next"));
  assert.match(run.notes.at(-1)?.text ?? "", /kickoff failed: the provider is gone/);
  assert.deepEqual(run.fatal, []);
  // The step is committed; only the kickoff is lost, and its marker is absent.
  assert.equal(run.read().pending, undefined);
  assert.equal(run.read().step, "plan");
  assert.equal(run.read().steps.at(-1)?.kickoffSent, undefined);
  assert.deepEqual(run.sent, []);

  run.setKickoffThrows(false);
  await command(run.deps, run.runtime, "resume");
  assert.deepEqual(run.switches, [join(run.dir, "s1.jsonl")]);
  assert.deepEqual(run.sent, [{ text: `/skill:flow-plan ${run.dir}`, expand: true }]);
  assert.equal(run.read().steps.at(-1)?.kickoffSent, true);
});

test("a running subagent refuses the advance", async () => {
  const run = harness({ flow: { step: "run" }, hasRunning: true });
  await command(run.deps, run.runtime, "next");
  assert.equal(run.atNewSession.length, 0);
  assert.match(run.notes.at(-1)?.text ?? "", /subagent is still running/);
});

test("a step whose session never started refuses to advance", async () => {
  const run = harness({
    flow: {
      step: "plan",
      pending: { step: "plan", model: "fixture/none", thinking: "high", kickoff: "x" },
    },
  });
  await command(run.deps, run.runtime, "next");
  assert.equal(run.atNewSession.length, 0);
  assert.match(run.notes.at(-1)?.text ?? "", /never started/);
});

test("a corrupt FLOW.json is reported and left as it is", async () => {
  const run = harness();
  writeFileSync(flowPath(run.dir), "{ half a file");
  await command(run.deps, run.runtime, "next");
  await command(run.deps, run.runtime, "status");
  assert.match(run.notes[0].text, /half a file|not JSON/);
  assert.match(run.notes[1].text, /not JSON/);
  assert.equal(readFileSync(flowPath(run.dir), "utf8"), "{ half a file");
});

test("resume retries the pending step, or reopens the recorded session", async () => {
  const pending = harness({
    flow: {
      step: "plan",
      pending: {
        step: "plan",
        model: "fixture/deep",
        thinking: "high",
        kickoff: "/skill:flow-plan x",
      },
    },
    registry: { "fixture/deep": { provider: "fixture", id: "deep" } },
  });
  await command(pending.deps, pending.runtime, "resume");
  assert.equal(pending.atNewSession.length, 1);
  assert.equal(pending.switches.length, 0);

  const recorded = harness({
    flow: {
      step: "plan",
      steps: [
        {
          step: "brief",
          session: "/s/brief.jsonl",
          model: "m/1",
          thinking: "low",
          startedAt: 1,
          endedAt: 2,
          cost: 0,
        },
        { step: "plan", session: "/s/plan.jsonl", model: "m/1", thinking: "high", startedAt: 3 },
      ],
    },
  });
  await command(recorded.deps, recorded.runtime, "resume");
  assert.deepEqual(recorded.switches, ["/s/plan.jsonl"]);
  assert.equal(recorded.atNewSession.length, 0);
});

test("the status names every step, the settings and what blocks on the owner", async () => {
  const run = harness({
    cost: 0,
    flow: {
      step: "run",
      mode: "deviation",
      steps: [
        {
          step: "brief",
          session: "/s/brief.jsonl",
          model: "m/1",
          thinking: "low",
          startedAt: 1,
          endedAt: 2,
          cost: 3.5,
        },
        {
          step: "plan",
          session: "/s/plan.jsonl",
          model: "m/2",
          thinking: "high",
          startedAt: 3,
          endedAt: 4,
          cost: 1.25,
        },
        {
          step: "run",
          session: "/s/run.jsonl",
          model: "m/3",
          thinking: "low",
          startedAt: 5,
          note: "Keep the existing public API.",
        },
      ],
    },
  });
  writeFileSync(
    join(run.dir, "PROGRESS.md"),
    "# Progress\n\n## Blocked on you\n\n- A2 needs the owner's YubiKey.\n- A5 waits on G0.\n\n## Log\n\n- written\n",
  );
  await command(run.deps, run.runtime, "status");
  const text = run.notes.at(-1)?.text ?? "";
  for (const step of ["brief", "plan", "approve", "run", "guide", "done"])
    assert.match(text, new RegExp(step));
  assert.match(text, /deviation mode/);
  assert.match(text, /spend \$4\.7500/);
  assert.match(text, /settings: judge .*, plan .*, run /);
  assert.match(text, /run: \/s\/run\.jsonl[^\n]*\n    note: Keep the existing public API\./);
  assert.match(text, /- A2 needs the owner's YubiKey\.\n- A5 waits on G0\./);
  assert.doesNotMatch(text, /- written/);
  assert.match(run.statuses.at(-1) ?? "", /^flow demo · run · \$4\.7500$/);
});

test("blockedOn keeps the section verbatim and stops at the next heading", () => {
  const progress = "## Blocked on you\n\n- one\n- two\n\n### Detail\n- three\n";
  assert.equal(blockedOn(progress), "## Blocked on you\n\n- one\n- two");
  assert.equal(blockedOn("# Progress\n\nnothing"), undefined);
  assert.equal(blockedOn(undefined), undefined);
});

test("statusText reports an absent mode as gated", () => {
  const run = harness();
  const text = statusText(
    {
      slug: "demo",
      planDir: run.dir,
      repoMain: run.dir,
      base: "main",
      branch: "demo",
      step: "brief",
      quick: false,
      settings: DEFAULT_SETTINGS,
      budget: { costCap: 15, spentStep: 0, spentTotal: 0, lines: 0, linesCap: 0 },
    },
    run.flow,
  );
  assert.match(text, /gated mode/);
  assert.match(text, /full plan/);
});

test("the settled handler sends one /flow next, and none for an aborted turn", () => {
  const run = harness();
  run.runtime.request = { planDir: run.dir, step: "brief" };
  settled(run.pi, run.runtime, false, run.ctx);
  assert.deepEqual(run.sent, [{ text: "/flow next", expand: true }]);
  assert.equal(run.runtime.request, undefined);

  run.runtime.request = { planDir: run.dir, step: "brief" };
  settled(run.pi, run.runtime, true, run.ctx);
  assert.equal(run.sent.length, 1);
  assert.match(run.notes.at(-1)?.text ?? "", /aborted/);
});

test("/flow <slug> in a fresh session starts a brief and sends its kickoff", async () => {
  // A session with no flow entry yet, plus a git checkout to name the plan after.
  // HOME is the scratch dir: the plan directory lives under it, not the owner's.
  const cwd = mkdtempSync(join(tmpdir(), "flow-start-"));
  const home = mkdtempSync(join(tmpdir(), "flow-home-"));
  const was = process.env.HOME;
  process.env.HOME = home;
  const fresh = harness();
  writeFileSync(join(cwd, "README.md"), "x\n");
  execFileSync("git", ["init", "-q", cwd], { encoding: "utf8" });
  const ctx = {
    ...(fresh.ctx as unknown as Record<string, unknown>),
    cwd,
    sessionManager: {
      getEntries: () => [],
      getSessionFile: () => join(cwd, "s.jsonl"),
      getSessionId: () => "sid",
      getSessionDir: () => cwd,
    },
  } as unknown as ExtensionCommandContext;
  try {
    await command({ ...fresh.deps, ctx }, fresh.runtime, "demo");
  } finally {
    process.env.HOME = was;
  }
  assert.equal(fresh.sent.length, 1);
  assert.match(fresh.sent[0].text, /^\/skill:flow-brief .*\/plans\/demo$/);
  assert.equal(fresh.sent[0].expand, true);
  const written = `${home}/.local/share/agents/${cwd.split("/").at(-1)}/plans/demo/FLOW.json`;
  assert.equal(JSON.parse(readFileSync(written, "utf8")).step, "brief");
});

test("a slug git rejects writes no flow and sends no brief", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "flow-slug-"));
  const home = mkdtempSync(join(tmpdir(), "flow-slug-home-"));
  execFileSync("git", ["init", "-q", cwd]);
  const fresh = harness();
  const ctx = {
    ...(fresh.ctx as unknown as Record<string, unknown>),
    cwd,
    sessionManager: {
      getEntries: () => [],
      getSessionFile: () => join(cwd, "s.jsonl"),
      getSessionId: () => "sid",
      getSessionDir: () => cwd,
    },
  } as unknown as ExtensionCommandContext;
  const was = process.env.HOME;
  process.env.HOME = home;
  try {
    await command({ ...fresh.deps, ctx }, fresh.runtime, "foo..bar");
  } finally {
    process.env.HOME = was;
  }
  assert.deepEqual(fresh.sent, []);
  assert.match(fresh.notes.at(-1)?.text ?? "", /not a usable slug/);
  assert.equal(
    existsSync(`${home}/.local/share/agents/${cwd.split("/").at(-1)}/plans/foo..bar/FLOW.json`),
    false,
  );
});

test("a slug is letters, digits, dot, dash and underscore, in a form git takes", () => {
  for (const slug of ["export-csv", "v1.2_fix", "A9"]) assert.equal(validSlug(slug), true, slug);
  for (const slug of ["a/b", "feature/x", "foo..bar", ".hidden", "-x", "x.lock", "a b", "ø"])
    assert.equal(validSlug(slug), false, slug);
});

test("a throwing send on a resume into the step's session is reported and keeps pi alive", async () => {
  const run = harness({
    kickoffThrows: true,
    flow: {
      step: "plan",
      steps: [
        {
          step: "brief",
          session: "/s/brief.jsonl",
          model: "m/1",
          thinking: "low",
          startedAt: 1,
          endedAt: 2,
          cost: 0,
        },
        { step: "plan", session: "/s/plan.jsonl", model: "m/1", thinking: "high", startedAt: 3 },
      ],
    },
  });
  await assert.doesNotReject(command(run.deps, run.runtime, "resume"));
  assert.deepEqual(run.switches, ["/s/plan.jsonl"]);
  assert.deepEqual(run.fatal, [], "a throw escaped withSession, which exits pi");
  assert.match(run.notes.at(-1)?.text ?? "", /plan kickoff failed: the provider is gone/);
  assert.equal(run.read().steps.at(-1)?.kickoffSent, undefined);

  // A FLOW.json that stops parsing mid-resume is reported the same way.
  run.setKickoffThrows(false);
  const ctx = run.deps.ctx as unknown as {
    switchSession: (path: string, init?: unknown) => Promise<unknown>;
  };
  const real = ctx.switchSession;
  ctx.switchSession = async (path, init) => {
    writeFileSync(flowPath(run.dir), "{ torn");
    return real(path, init);
  };
  await assert.doesNotReject(command(run.deps, run.runtime, "resume"));
  assert.deepEqual(run.switches, ["/s/plan.jsonl", "/s/plan.jsonl"]);
  assert.deepEqual(run.fatal, []);
  assert.match(run.notes.at(-1)?.text ?? "", /could not record it/);
});

test("a throwing same-session resend is not marked sent, so the next resume sends it", async () => {
  const run = harness({ piSendThrows: true });
  await assert.doesNotReject(command(run.deps, run.runtime, "resume"));
  assert.deepEqual(run.switches, []);
  assert.deepEqual(run.sent, []);
  assert.match(run.notes.at(-1)?.text ?? "", /brief kickoff failed: the provider is gone/);
  assert.equal(run.read().steps[0]?.kickoffSent, undefined);

  run.setPiSendThrows(false);
  await command(run.deps, run.runtime, "resume");
  assert.deepEqual(run.sent, [{ text: `/skill:flow-brief ${run.dir}`, expand: true }]);
  assert.equal(run.read().steps[0]?.kickoffSent, true);
  assert.match(run.notes.at(-1)?.text ?? "", /resent the brief kickoff/);
});

test("a resume from a streaming session is not marked sent, so an idle resume sends it", async () => {
  const run = harness({ streaming: true });
  await command(run.deps, run.runtime, "resume");

  assert.deepEqual(run.switches, []);
  assert.deepEqual(run.sent, [], "a streaming session must not take the kickoff");
  assert.match(run.notes.at(-1)?.text ?? "", /a turn is still running/);
  assert.equal(run.read().steps[0]?.kickoffSent, undefined);

  run.setStreaming(false);
  await command(run.deps, run.runtime, "resume");
  assert.deepEqual(run.sent, [{ text: `/skill:flow-brief ${run.dir}`, expand: true }]);
  assert.equal(run.read().steps[0]?.kickoffSent, true);
});
