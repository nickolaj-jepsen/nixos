/**
 * A1's tool tests: `flow_next`'s refusals and its idempotency per step, and
 * `flow_status`'s budget — the caps from the handoff, the spend from the step
 * records, and the diff lines from a real repository.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { budgetCaps, DEFAULT_SETTINGS, type Flow } from "./contracts.ts";
import { parseHandoff } from "./handoff.ts";
import { flowPath, FLOW_ENTRY, newFlow, readFlow, writeFlow } from "./state.ts";
import { createRuntime, nextTool, statusOf } from "./tools.ts";

const scratch = (): string => mkdtempSync(join(tmpdir(), "flow-tools-"));

const demo = (planDir: string, overrides: Partial<Flow> = {}): Flow => ({
  ...newFlow({
    slug: "demo",
    planDir,
    repoMain: planDir,
    base: "main",
    branch: "demo",
    model: "fixture/replay",
    thinking: "low",
    session: join(planDir, "brief.jsonl"),
    at: 1_000,
  }),
  ...overrides,
});

/** A context whose session carries this flow's entry; the flow is not in it when `planDir` is absent. */
const ctxOf = (
  planDir: string | undefined,
  extra: Record<string, unknown> = {},
): ExtensionContext =>
  ({
    ui: { notify: () => {}, setStatus: () => {} },
    mode: "tui",
    hasUI: true,
    cwd: planDir ?? "/tmp",
    sessionManager: {
      getEntries: () =>
        planDir
          ? [
              {
                type: "custom",
                customType: FLOW_ENTRY,
                data: { planDir, slug: "demo" },
                id: "e1",
                parentId: null,
                timestamp: "",
              },
            ]
          : [],
      getSessionFile: () => join(planDir ?? "/tmp", "brief.jsonl"),
      getSessionId: () => "s",
      getSessionDir: () => planDir ?? "/tmp",
    },
    ...extra,
  }) as unknown as ExtensionContext;

const deps = (overrides: Partial<Parameters<typeof nextTool>[0]> = {}) => ({
  runtime: createRuntime(),
  now: () => 2_000,
  hasRunning: () => false,
  cost: () => 0.25,
  ...overrides,
});

test("flow_next outside a flow session refuses", () => {
  const outcome = nextTool(deps(), ctxOf(undefined));
  assert.equal(outcome.isError, true);
  assert.match(outcome.text, /\/flow <slug>/);
});

test("flow_next leaves the step open and asks for one advance", () => {
  const dir = scratch();
  writeFlow(demo(dir));
  const runtime = createRuntime();
  const outcome = nextTool(deps({ runtime }), ctxOf(dir));
  assert.equal(outcome.isError ?? false, false);
  const read = readFlow(dir);
  assert.equal(read.kind, "ok");
  const record = read.kind === "ok" ? read.flow.steps[0] : undefined;
  assert.equal(record?.endedAt, undefined);
  assert.equal(record?.cost, undefined);
  assert.deepEqual(runtime.request, { planDir: dir, step: "brief" });
  assert.deepEqual(runtime.advancing, { planDir: dir, step: "brief" });
});

test("flow_next stores and returns its note without closing the step", () => {
  const dir = scratch();
  writeFlow(demo(dir));
  const outcome = nextTool(deps(), ctxOf(dir), "The brief kept the existing API.");
  assert.match(outcome.text, /Note: The brief kept the existing API\./);
  const read = readFlow(dir);
  assert.equal(read.kind, "ok");
  if (read.kind !== "ok") return;
  assert.equal(read.flow.steps[0]?.note, "The brief kept the existing API.");
  assert.equal(read.flow.steps[0]?.endedAt, undefined);
  const status = statusOf(deps(), ctxOf(dir), read.flow, DEFAULT_SETTINGS);
  assert.equal(status.budget.spentStep, 0.25);
});

test("flow_next takes a note when the step has no record to keep it on", () => {
  const dir = scratch();
  // A brief started in an unsaved session has no step record.
  writeFlow(demo(dir, { steps: [] }));
  const runtime = createRuntime();
  const outcome = nextTool(deps({ runtime }), ctxOf(dir), "Two decisions, one open question.");
  assert.equal(outcome.isError ?? false, false, outcome.text);
  assert.match(outcome.text, /Note: Two decisions, one open question\./);
  assert.deepEqual(runtime.request, { planDir: dir, step: "brief" });
  const read = readFlow(dir);
  assert.deepEqual(read.kind === "ok" ? read.flow.steps : "read", []);
});

test("a second flow_next in the same step is a no-op", () => {
  const dir = scratch();
  writeFlow(demo(dir));
  const runtime = createRuntime();
  nextTool(deps({ runtime }), ctxOf(dir));
  const first = readFlow(dir);
  const again = nextTool(deps({ runtime, cost: () => 9 }), ctxOf(dir));
  assert.equal(again.isError ?? false, false);
  assert.match(again.text, /already advancing/);
  const second = readFlow(dir);
  assert.deepEqual(second, first);
  assert.deepEqual(runtime.request, { planDir: dir, step: "brief" });
});

test("flow_next refuses while a subagent is running, and writes nothing", () => {
  const dir = scratch();
  writeFlow(demo(dir));
  const runtime = createRuntime();
  const outcome = nextTool(deps({ runtime, hasRunning: () => true }), ctxOf(dir));
  assert.equal(outcome.isError, true);
  assert.match(outcome.text, /subagent/);
  assert.equal(runtime.request, undefined);
  const read = readFlow(dir);
  assert.equal(read.kind === "ok" ? read.flow.steps[0].endedAt : "read", undefined);
});

test("flow_next refuses a corrupt FLOW.json and leaves it as it is", () => {
  const dir = scratch();
  writeFileSync(flowPath(dir), "{ nope");
  const outcome = nextTool(deps(), ctxOf(dir));
  assert.equal(outcome.isError, true);
  assert.match(outcome.text, /refused/);
  assert.equal(readFlow(dir).kind, "corrupt");
});

test("flow_status's caps come from the handoff and its lines from the branch", () => {
  const dir = scratch();
  const git = (args: string[]) =>
    execFileSync("git", ["-c", "user.email=f@e.invalid", "-c", "user.name=F", ...args], {
      cwd: dir,
      encoding: "utf8",
    }).trim();
  git(["init", "-q"]);
  writeFileSync(join(dir, "a.ts"), "export const a = 1;\n");
  git(["add", "."]);
  git(["commit", "-qm", "one"]);
  git(["checkout", "-q", "-b", "demo"]);
  writeFileSync(join(dir, "a.ts"), "export const a = 2;\nexport const b = 3;\n");
  git(["commit", "-qam", "two"]);

  const flow = demo(dir, { repoMain: dir, base: "main", branch: "demo" });
  // No HANDOFF.md yet: no cap on either axis.
  const bare = statusOf(deps(), ctxOf(dir), flow, DEFAULT_SETTINGS);
  assert.equal(bare.budget.lines, 3);
  assert.deepEqual([bare.budget.costCap, bare.budget.linesCap], [0, 0]);

  const handoff = join(dir, "HANDOFF.md");
  copyFileSync(new URL("./handoff-example.md", import.meta.url), handoff);
  const parsed = parseHandoff(readFileSync(handoff, "utf8"));
  const caps = parsed.ok ? budgetCaps(parsed.handoff.budget) : undefined;
  const status = statusOf(deps(), ctxOf(dir), flow, DEFAULT_SETTINGS);
  assert.deepEqual(
    [status.budget.costCap, status.budget.linesCap],
    [caps?.costCap, caps?.linesCap],
  );
  assert.ok(status.budget.costCap > 0);
  assert.equal(status.budget.lines, 3);
  assert.equal(status.slug, "demo");
  assert.equal(status.base, "main");
  assert.equal(status.branch, "demo");
  assert.equal(status.repoMain, dir);
});

test("flow_status counts each ledger once: a judge's cost is already in its step's", () => {
  const dir = scratch();
  const flow = demo(dir, {
    step: "plan",
    steps: [
      {
        step: "brief",
        session: join(dir, "brief.jsonl"),
        model: "fixture/replay",
        thinking: "low",
        startedAt: 1,
        endedAt: 2,
        cost: 0.5,
      },
      {
        step: "plan",
        session: join(dir, "plan.jsonl"),
        model: "fixture/deep",
        thinking: "high",
        startedAt: 3,
      },
    ],
    judge: [{ at: "brief", verdict: {}, cost: 0.125, model: "fixture/none" }],
  });
  const status = statusOf(deps({ cost: () => 0.25 }), ctxOf(dir), flow, DEFAULT_SETTINGS);
  assert.equal(status.budget.spentStep, 0.25);
  // The judge ran in the brief session, so the brief's $0.5 already holds its $0.125.
  assert.equal(status.budget.spentTotal, 0.5 + 0.25);
  assert.equal(status.step, "plan");
  assert.equal(status.mode, undefined);
});
