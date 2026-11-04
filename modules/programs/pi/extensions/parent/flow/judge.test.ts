/**
 * A3's judge: the two verdicts it reads out of a flash reply, and what it does
 * when the reply is not one (C4, D6).
 *
 * The side call is a parameter, so nothing here reaches a model: each case hands
 * the judge a reply and asserts the verdict, the request it made and the cost it
 * carried. The reply shapes are the ones the prompts ask for — a strict JSON
 * object — and the failures are the ones a flash model actually produces.
 *
 * `side-call.ts` imports pi-ai for `contentText`, which only pi can load, so the
 * package is stubbed before the module under test, as `parent/review/live.test.ts`
 * does.
 */
import { registerHooks } from "node:module";
import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { SideCall, SideResult } from "../../shared/side-call.ts";
import {
  DEFAULT_SETTINGS,
  type HandoffItem,
  type ParsedHandoff,
  resolveSettings,
  type ResolvedSettings,
  type Tier,
} from "./contracts.ts";
import type { JudgeCall } from "./judge.ts";

const moduleUrl = (source: string) => `data:text/javascript,${encodeURIComponent(source)}`;

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "@earendil-works/pi-ai") {
      return { url: moduleUrl(`export const contentText = () => "";`), shortCircuit: true };
    }
    return next(specifier, context);
  },
});

// Loaded after the stub: this is the module that reaches pi-ai through side-call.ts.
const { judgeBrief, judgeHandoff } = await import("./judge.ts");

// The judge touches neither of these itself: sideCall reads the registry, the ledger writes entries.
const pi = { appendEntry: () => {} } as unknown as ExtensionAPI;
const ctx = {} as unknown as ExtensionContext;

/** D5's settings, with this case's overrides laid over them. */
const settings = (over: unknown = {}): ResolvedSettings =>
  resolveSettings(DEFAULT_SETTINGS, {}, over).settings;

/** The side call the judge gets: it answers with `reply` and keeps every request. */
const answering = (reply: SideResult | (() => SideResult)) => {
  const requests: SideCall[] = [];
  const call: JudgeCall = async (_pi, _ctx, request) => {
    requests.push(request);
    return typeof reply === "function" ? reply() : reply;
  };
  return { call, requests };
};

const item = (id: string, tier: Tier = "flash"): HandoffItem => ({
  id,
  title: `the ${id} item`,
  spike: false,
  blockedBy: [],
  owns: [`E/parent/flow/${id}.ts`],
  adds: "nothing",
  tier,
  tierLine: 1,
  outcome: `${id} does its part`,
  acceptance: `npm test passes`,
  acceptanceUnverified: false,
  constraints: "C4",
  line: 1,
});

/** A plan small enough to read in a prompt: every item flash unless the case says otherwise. */
const handoff = (items: HandoffItem[] = [item("A1"), item("A2"), item("A3")]): ParsedHandoff => ({
  mission: "Build the thing.",
  smallestVersion: "The smallest thing that works.",
  notBuilding: ["a Claude Code port"],
  scope: "In: the thing\n\nOut: everything else",
  context: "- the repo",
  yours: [],
  defaults: [],
  uncertain: [],
  items,
  contracts: [],
  budget: { newFiles: 4, newAbstractions: 1, lines: 100, costCap: 2, concurrency: 2 },
  stops: ["the final gate"],
  openQuestions: [],
  amendments: "",
  sections: {},
});

const brief = "# Brief\n\nRename one constant in b.ts.\n";

test("a brief verdict comes back with its reasons and what the call cost", async () => {
  const { call, requests } = answering({
    text: JSON.stringify({
      plan: "quick",
      model: "vm/flash",
      thinking: "high",
      reasons: {
        plan: "one constant in one file",
        model: "flash reads one file well enough",
        thinking: "the rename has one obvious place",
      },
    }),
    cost: 0.004,
  });
  const verdict = await judgeBrief(pi, ctx, brief, settings(), call);

  assert.equal(verdict.plan, "quick");
  assert.equal(verdict.model, "vm/flash");
  assert.equal(verdict.thinking, "high");
  assert.deepEqual(verdict.reasons, [
    "one constant in one file",
    "flash reads one file well enough",
    "the rename has one obvious place",
  ]);
  assert.equal(verdict.cost, 0.004);

  assert.equal(requests.length, 1);
  const request = requests[0]!;
  assert.equal(request.source, "flow-judge");
  // D5's `judge` row: the call runs on flash, at its thinking level.
  assert.equal(request.model, "vm/flash");
  assert.equal(request.reasoning, "low");
  assert.ok(request.maxTokens > 0);
  assert.ok(request.timeoutMs > 0);
  assert.match(request.prompt, /Rename one constant in b\.ts\./);
  // Nothing outside the flow's own configuration may be suggested.
  assert.match(request.system, /- models: vm\/deep, vm\/flash/);
  assert.match(request.system, /- thinking levels: off, minimal, low, medium, high, xhigh, max/);
});

test("a judge setting moves the call, and reasoning off is no reasoning option", async () => {
  const { call, requests } = answering({
    text: JSON.stringify({
      plan: "full",
      model: "fixture/replay",
      thinking: "max",
      reasons: { plan: "hard", model: "deep", thinking: "max" },
    }),
    cost: 0,
  });
  const verdict = await judgeBrief(
    pi,
    ctx,
    brief,
    settings({ judge: { model: "fixture/replay", thinking: "off" } }),
    call,
  );

  // The judge's own model is one of the flow's models, so it may suggest it back.
  assert.equal(verdict.model, "fixture/replay");
  assert.equal(verdict.thinking, "max");
  assert.equal(requests[0]?.model, "fixture/replay");
  assert.equal(requests[0]?.reasoning, undefined);
  assert.match(requests[0]?.system ?? "", /- models: fixture\/replay, vm\/deep, vm\/flash/);
});

test("a reply that is not JSON gives the plan defaults, with the failure as the reason", async () => {
  const { call } = answering({ text: "I would use the deep model, it is better.", cost: 0.002 });
  const verdict = await judgeBrief(pi, ctx, brief, settings(), call);

  assert.equal(verdict.plan, "full");
  assert.equal(verdict.model, "vm/deep");
  assert.equal(verdict.thinking, "high");
  assert.equal(verdict.reasons.length, 1);
  assert.match(verdict.reasons[0]!, /JSON/);
  // A billed reply keeps its cost, even when its text is unusable.
  assert.equal(verdict.cost, 0.002);
});

test("a failed call gives the defaults with its error as the reason", async () => {
  const { call } = answering({ error: "request timed out after 20000ms", cost: 0 });
  const verdict = await judgeBrief(pi, ctx, brief, settings(), call);

  assert.equal(verdict.plan, "full");
  assert.equal(verdict.model, "vm/deep");
  assert.deepEqual(verdict.reasons, ["the judge call failed: request timed out after 20000ms"]);
  assert.equal(verdict.cost, 0);
});

test("a side call that throws is still a default verdict, never a throw", async () => {
  const { call } = answering(() => {
    throw new Error("socket closed");
  });
  const verdict = await judgeBrief(pi, ctx, brief, settings(), call);

  assert.equal(verdict.plan, "full");
  assert.deepEqual(verdict.reasons, ["the judge call failed: socket closed"]);
});

test("a model this flow does not configure gives the defaults", async () => {
  const { call } = answering({
    text: JSON.stringify({
      plan: "full",
      model: "anthropic/claude-opus",
      thinking: "max",
      reasons: { plan: "hard", model: "the best model", thinking: "hard" },
    }),
    cost: 0.01,
  });
  const verdict = await judgeBrief(pi, ctx, brief, settings(), call);

  assert.equal(verdict.plan, "full");
  assert.equal(verdict.model, "vm/deep");
  assert.equal(verdict.thinking, "high");
  assert.match(verdict.reasons[0]!, /anthropic\/claude-opus/);
});

test("a thinking level that does not exist gives the defaults", async () => {
  const { call } = answering({
    text: JSON.stringify({
      plan: "full",
      model: "vm/deep",
      thinking: "extreme",
      reasons: { plan: "hard", model: "deep", thinking: "very hard" },
    }),
    cost: 0,
  });
  const verdict = await judgeBrief(pi, ctx, brief, settings(), call);

  assert.equal(verdict.thinking, "high");
  assert.match(verdict.reasons[0]!, /"extreme"/);
});

test("a handoff verdict comes back with its mode, run step, tiers and cost", async () => {
  const { call, requests } = answering({
    text: JSON.stringify({
      mode: "deviation",
      run: { model: "vm/deep", thinking: "max" },
      tiers: { A2: "deep" },
      finalReview: "reviewer-deep",
      reasons: {
        mode: "A2 changes a contract",
        run: "the run lead holds three gates",
        finalReview: "one merged pass reads best",
        A2: "A2 rewrites the contract, nothing else does",
      },
    }),
    cost: 0.012,
  });
  const verdict = await judgeHandoff(pi, ctx, handoff(), settings(), call);

  assert.equal(verdict.mode, "deviation");
  assert.deepEqual(verdict.run, { model: "vm/deep", thinking: "max" });
  assert.deepEqual(verdict.tiers, { A2: "deep" });
  assert.equal(verdict.finalReview, "reviewer-deep");
  assert.equal(verdict.cost, 0.012);
  assert.equal(verdict.reasons.length, 4);

  const request = requests[0]!;
  assert.equal(request.source, "flow-judge");
  assert.match(request.prompt, /- A1 \[flash\] the A1 item: A1 does its part/);
  assert.match(request.prompt, /\$2 cap/);
  assert.match(request.system, /- roles: builder, builder-deep, reviewer, reviewer-deep/);
  assert.match(request.system, /- modes: gated, deviation, straight/);
});

test("an unknown item id in the tiers gives the whole verdict's defaults", async () => {
  const { call } = answering({
    text: JSON.stringify({
      mode: "straight",
      run: { model: "vm/deep", thinking: "max" },
      tiers: { Z9: "deep" },
      finalReview: "reviewer-deep",
      reasons: { mode: "routine", run: "large", finalReview: "large", Z9: "the risky one" },
    }),
    cost: 0.01,
  });
  const verdict = await judgeHandoff(pi, ctx, handoff(), settings(), call);

  assert.equal(verdict.mode, "gated");
  assert.deepEqual(verdict.run, { model: "vm/flash", thinking: "low" });
  assert.deepEqual(verdict.tiers, {});
  assert.equal(verdict.finalReview, "reviewer-deep");
  assert.match(verdict.reasons[0]!, /Z9, which is not an item/);
});

test("a deep tier without a reason naming the item is dropped, the rest of the verdict kept", async () => {
  const { call } = answering({
    text: JSON.stringify({
      mode: "deviation",
      run: { model: "vm/flash", thinking: "low" },
      tiers: { A1: "deep", A2: "deep", A3: "flash" },
      finalReview: "reviewer-deep",
      reasons: {
        mode: "two contracts move",
        run: "the lead only routes",
        finalReview: "one pass",
        A1: "A1 carries the whole parser",
        A2: "this one is harder than it looks",
      },
    }),
    cost: 0.008,
  });
  // Every item starts flash, so A2's upgrade is the one with no naming reason.
  const verdict = await judgeHandoff(pi, ctx, handoff(), settings(), call);

  assert.deepEqual(verdict.tiers, { A1: "deep" });
  assert.equal(verdict.mode, "deviation");
  assert.deepEqual(verdict.run, { model: "vm/flash", thinking: "low" });
  assert.equal(verdict.cost, 0.008);
});

test("a tier suggestion that changes nothing is no move", async () => {
  const { call } = answering({
    text: JSON.stringify({
      mode: "gated",
      run: { model: "vm/flash", thinking: "low" },
      tiers: { A1: "flash", A2: "deep" },
      finalReview: "reviewer-deep",
      reasons: {
        mode: "every gate",
        run: "cheap",
        finalReview: "the last word",
        A2: "A2 already ships deep",
      },
    }),
    cost: 0,
  });
  const verdict = await judgeHandoff(
    pi,
    ctx,
    handoff([item("A1"), item("A2", "deep")]),
    settings(),
    call,
  );

  assert.deepEqual(verdict.tiers, {});
});

test("a role this flow does not configure gives the defaults", async () => {
  const { call } = answering({
    text: JSON.stringify({
      mode: "straight",
      run: { model: "vm/flash", thinking: "low" },
      tiers: {},
      finalReview: "super-reviewer",
      reasons: { mode: "routine", run: "cheap", finalReview: "the strict one" },
    }),
    cost: 0,
  });
  const verdict = await judgeHandoff(pi, ctx, handoff(), settings(), call);

  assert.equal(verdict.finalReview, "reviewer-deep");
  assert.equal(verdict.mode, "gated");
  assert.match(verdict.reasons[0]!, /super-reviewer/);
});

test("a handoff reply with no reasons gives the defaults", async () => {
  const { call } = answering({
    text: JSON.stringify({ mode: "straight", run: { model: "vm/flash", thinking: "low" } }),
    cost: 0.005,
  });
  const verdict = await judgeHandoff(pi, ctx, handoff(), settings(), call);

  assert.equal(verdict.mode, "gated");
  assert.match(verdict.reasons[0]!, /no reason/);
  assert.equal(verdict.cost, 0.005);
});

test("a verdict wrapped in a fenced block or a sentence is read anyway", async () => {
  const reply = {
    plan: "quick",
    model: "vm/flash",
    thinking: "low",
    reasons: { plan: "one file", model: "one file", thinking: "one file" },
  };
  for (const text of [
    `\`\`\`json\n${JSON.stringify(reply, null, 2)}\n\`\`\``,
    `Here is my answer: ${JSON.stringify(reply)} — nothing else changes.`,
  ]) {
    const { call } = answering({ text, cost: 0 });
    const verdict = await judgeBrief(pi, ctx, brief, settings(), call);
    assert.equal(verdict.plan, "quick");
    assert.equal(verdict.model, "vm/flash");
    assert.equal(verdict.thinking, "low");
  }
});
