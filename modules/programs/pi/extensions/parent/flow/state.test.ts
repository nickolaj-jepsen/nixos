/**
 * A1's state tests: the plan directory, FLOW.json's whole read and atomic
 * write, the step records a switch leaves behind, the settings layering, the
 * transition table, and the diff the budget counts against a real repository.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type Flow, parseFlow } from "./contracts.ts";
import {
  closeStep,
  defaultBase,
  diffLines,
  flowPath,
  mergeBase,
  newFlow,
  planDirFor,
  readFlow,
  readText,
  recordOf,
  settingsOf,
  transitionOf,
  writeFlow,
} from "./state.ts";

const scratch = (): string => mkdtempSync(join(tmpdir(), "flow-state-"));

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

const git = (cwd: string, args: string[]): string =>
  execFileSync(
    "git",
    [
      "-c",
      "user.email=flow@example.invalid",
      "-c",
      "user.name=Flow",
      "-c",
      "init.defaultBranch=main",
      ...args,
    ],
    { cwd, encoding: "utf8" },
  ).trim();

/** A repository with two commits on `main` and one on `feature` on top. */
const repo = (): string => {
  const dir = scratch();
  git(dir, ["init", "-q"]);
  writeFileSync(join(dir, "a.ts"), "export const a = 1;\n");
  writeFileSync(join(dir, "b.ts"), "export const b = 1;\nexport const c = 2;\n");
  git(dir, ["add", "."]);
  git(dir, ["commit", "-qm", "one"]);
  git(dir, ["checkout", "-q", "-b", "feature"]);
  writeFileSync(
    join(dir, "a.ts"),
    "export const a = 2;\nexport const b = 3;\nexport const c = 4;\n",
  );
  git(dir, ["commit", "-qam", "two"]);
  return dir;
};

test("the plan directory is under the main checkout's name", () => {
  const dir = planDirFor("/home/owner/nixos", "demo");
  assert.ok(dir.endsWith("/.local/share/agents/nixos/plans/demo"), dir);
});

test("FLOW.json round trips whole and leaves no temp file behind", () => {
  const dir = scratch();
  const flow = demo(dir, { steps: [] });
  writeFlow(flow);
  const read = readFlow(dir);
  assert.equal(read.kind, "ok");
  // The parser keeps absent optionals as `undefined` keys; the file's content is what matters.
  const plain = (value: unknown) => JSON.parse(JSON.stringify(value));
  assert.deepEqual(plain(read.kind === "ok" ? read.flow : undefined), plain(flow));
  assert.equal(parseFlow(readFileSync(flowPath(dir), "utf8")).ok, true);
  assert.deepEqual(readdirSync(dir), ["FLOW.json"]);
});

test("a missing FLOW.json is 'none', a broken one is 'corrupt' and is not rewritten", () => {
  const dir = scratch();
  assert.deepEqual(readFlow(dir), { kind: "none" });
  writeFileSync(flowPath(dir), "{ not json");
  const read = readFlow(dir);
  assert.equal(read.kind, "corrupt");
  assert.match(read.kind === "corrupt" ? read.error : "", /not JSON/);
  assert.equal(readFileSync(flowPath(dir), "utf8"), "{ not json");
});

test("readText is undefined for a missing file", () => {
  const dir = scratch();
  assert.equal(readText(join(dir, "BRIEF.md")), undefined);
  writeFileSync(join(dir, "BRIEF.md"), "hello");
  assert.equal(readText(join(dir, "BRIEF.md")), "hello");
});

test("closing a step records its end and cost once", () => {
  const dir = scratch();
  const flow = demo(dir);
  const closed = closeStep(flow, 2_000, 0.25);
  assert.equal(closed.steps[0].endedAt, 2_000);
  assert.equal(closed.steps[0].cost, 0.25);
  assert.deepEqual(closeStep(closed, 3_000, 9), closed);
});

test("the record a resume goes back to is the last one for that step", () => {
  const dir = scratch();
  const base = demo(dir);
  const flow: Flow = {
    ...base,
    steps: [
      ...base.steps,
      { step: "plan", session: "/p/one.jsonl", model: "m/1", thinking: "high", startedAt: 2 },
      { step: "plan", session: "/p/two.jsonl", model: "m/1", thinking: "high", startedAt: 3 },
    ],
  };
  assert.equal(recordOf(flow, "plan")?.session, "/p/two.jsonl");
  assert.equal(recordOf(flow, "guide"), undefined);
});

test("settings layer the leaf over the defaults and the flow over the leaf", () => {
  const dir = scratch();
  const flow = demo(dir, {
    settings: { plan: { model: "fixture/deep", thinking: "medium" }, run: { thinking: "max" } },
  });
  const { settings, reports } = settingsOf(
    { plan: { thinking: "low" }, judge: { model: "fixture/none" } },
    flow,
  );
  assert.deepEqual(reports, []);
  assert.equal(settings.plan.model, "fixture/deep");
  assert.equal(settings.plan.thinking, "medium");
  assert.equal(settings.judge.model, "fixture/none");
  assert.equal(settings.run.thinking, "max");
  assert.equal(settings.run.model, "vm/flash");
  // A bad value falls back to the layer below and is reported, never thrown.
  const fallback = settingsOf(null, demo(dir, { settings: { plan: { model: "no-slash" } } }));
  assert.equal(fallback.settings.plan.model, "vm/deep");
  assert.equal(fallback.reports.length, 1);
  assert.equal(fallback.reports[0].field, "model");
});

test("the transition table: what each step asks before the next one", () => {
  assert.deepEqual(transitionOf("brief", "gated"), { from: "brief", to: "plan", ask: "picker" });
  assert.deepEqual(transitionOf("plan", "gated"), { from: "plan", to: "approve", ask: "approval" });
  assert.deepEqual(transitionOf("approve", "deviation"), {
    from: "approve",
    to: "run",
    ask: "none",
  });
  for (const mode of ["deviation", "straight"] as const)
    assert.deepEqual(transitionOf("run", mode), { from: "run", to: "guide", ask: "none" });
  assert.deepEqual(transitionOf("run", "gated"), { from: "run", to: "guide", ask: "confirm" });
  assert.deepEqual(transitionOf("guide", "gated"), { from: "guide", to: "done", ask: "none" });
  assert.equal(transitionOf("done", "gated"), undefined);
});

test("the diff the budget counts is insertions plus deletions against the merge base", () => {
  const dir = repo();
  const base = mergeBase(dir, "main", "feature");
  assert.match(base ?? "", /^[0-9a-f]{40}$/);
  assert.equal(diffLines(dir, "main", "feature"), 4);
  assert.equal(diffLines(dir, "main", "missing-branch"), 0);
  assert.equal(defaultBase(dir), "main");
  rmSync(dir, { recursive: true, force: true });
});

test("a new flow starts at the brief step, in the session that started it", () => {
  const dir = scratch();
  const flow = demo(dir);
  assert.equal(flow.step, "brief");
  assert.equal(flow.quick, false);
  assert.deepEqual(flow.settings, {});
  assert.deepEqual(flow.judge, []);
  assert.equal(flow.steps.length, 1);
  assert.equal(flow.steps[0].step, "brief");
  assert.equal(flow.steps[0].session, join(dir, "brief.jsonl"));
});
