/**
 * G0's contract tests: the state file's parser (C1), the settings resolution and
 * step table (C2), and the handoff grammar's example (C6) as far as it can be
 * checked without A2's parser. A2 parses the same example for real.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  DEFAULT_SETTINGS,
  type Flow,
  ITEM_ID,
  isLevel,
  isModelRef,
  kickoffFor,
  parseFlow,
  resolveSettings,
  settingKeyFor,
  STEPS,
} from "./contracts.ts";

const example = readFileSync(new URL("./handoff-example.md", import.meta.url), "utf8");

const flow = (overrides: Record<string, unknown> = {}) => ({
  v: 1,
  slug: "demo",
  planDir: "/home/owner/.local/share/agents/app/plans/demo",
  repoMain: "/home/owner/app",
  base: "main",
  branch: "demo",
  step: "brief",
  quick: false,
  settings: {},
  steps: [],
  judge: [],
  ...overrides,
});

const cloned = (overrides: Record<string, unknown> = {}) =>
  JSON.parse(JSON.stringify(flow(overrides)));

test("a well-formed FLOW.json parses whole", () => {
  const result = parseFlow(
    JSON.stringify({
      ...flow(),
      step: "run",
      mode: "deviation",
      quick: true,
      settings: { run: { model: "vm/deep", thinking: "high" } },
      pending: {
        step: "guide",
        model: "vm/flash",
        thinking: "low",
        kickoff: "/skill:flow-guide /p",
      },
      steps: [
        {
          step: "brief",
          session: "/sessions/a.jsonl",
          model: "vm/flash",
          thinking: "low",
          startedAt: 1,
          endedAt: 2,
          cost: 0.25,
        },
      ],
      judge: [{ at: "brief", verdict: { plan: "full" }, cost: 0.01, model: "vm/flash" }],
      tour: {
        slug: "app/main/commits/a..b",
        argv: ["-r", "a..b"],
        cwd: "/home/owner/app",
        rv: "/rv -r a..b",
      },
    }),
  );
  assert.equal(result.ok, true);
  if (!result.ok) return;
  const parsed: Flow = result.flow;
  assert.equal(parsed.mode, "deviation");
  assert.equal(parsed.steps[0]?.cost, 0.25);
  assert.equal(parsed.pending?.step, "guide");
  assert.deepEqual(parsed.tour?.argv, ["-r", "a..b"]);
  assert.equal(parsed.judge.length, 1);
});

test("an unknown key is tolerated, so a newer file still opens", () => {
  const result = parseFlow(JSON.stringify(flow({ future: { anything: true } })));
  assert.equal(result.ok, true);
});

test("a corrupt FLOW.json fails with the field that broke", () => {
  const cases: [Record<string, unknown>, RegExp][] = [
    [{ v: 2 }, /^v must be 1$/],
    [{ slug: "" }, /^slug must be/],
    [{ repoMain: 7 }, /^repoMain must be/],
    [{ step: "review" }, /^step must be/],
    [{ mode: "auto" }, /^mode must be/],
    [{ quick: "no" }, /^quick must be/],
    [{ settings: [] }, /^settings must be/],
    [{ pending: { step: "plan" } }, /^pending\.model must be/],
    [
      { pending: { step: "plan", model: "vm/flash", thinking: "maxx", kickoff: "" } },
      /^pending\.thinking must be/,
    ],
    [{ steps: [{ step: "brief" }] }, /^steps\[0\]\.session must be/],
    [
      { steps: [{ step: "brief", session: "s", model: "m", thinking: "low", startedAt: "then" }] },
      /startedAt/,
    ],
    [{ judge: [{ at: "plan", verdict: {}, cost: 0, model: "m" }] }, /^judge\[0\]\.at must be/],
    [{ tour: { slug: "s", argv: "x", cwd: "/c", rv: "/rv" } }, /^tour\.argv must be/],
  ];
  for (const [overrides, expected] of cases) {
    const result = parseFlow(JSON.stringify(cloned(overrides)));
    assert.equal(result.ok, false, `expected ${JSON.stringify(overrides)} to fail`);
    if (result.ok) continue;
    assert.match(result.error, expected);
  }
});

test("only JSON parses", () => {
  const result = parseFlow("{nope");
  assert.equal(result.ok, false);
  if (!result.ok) assert.match(result.error, /^not JSON/);
  assert.equal(parseFlow("[]").ok, false);
});

test("the defaults are D5's table", () => {
  assert.deepEqual(DEFAULT_SETTINGS.judge, { model: "vm/flash", thinking: "low" });
  assert.deepEqual(DEFAULT_SETTINGS.plan, { model: "vm/deep", thinking: "high" });
  assert.deepEqual(DEFAULT_SETTINGS.planQuick, { model: "vm/flash", thinking: "high" });
  assert.deepEqual(DEFAULT_SETTINGS.run, { model: "vm/flash", thinking: "low" });
  assert.deepEqual(DEFAULT_SETTINGS.items, { role: "builder", thinking: "high" });
  assert.deepEqual(DEFAULT_SETTINGS.itemsDeep, { role: "builder-deep", thinking: "high" });
  assert.deepEqual(DEFAULT_SETTINGS.gateReview, { role: "reviewer" });
  assert.deepEqual(DEFAULT_SETTINGS.finalReview, { role: "reviewer-deep", thinking: "high" });
  assert.deepEqual(DEFAULT_SETTINGS.simplify, { role: "builder", thinking: "high" });
});

test("no overrides leaves the defaults and nothing to report", () => {
  const { settings, reports } = resolveSettings(DEFAULT_SETTINGS, undefined, {});
  assert.deepEqual(settings, DEFAULT_SETTINGS);
  assert.deepEqual(reports, []);
});

test("the leaf overrides, and a flow overrides the leaf, field by field", () => {
  const { settings, reports } = resolveSettings(
    DEFAULT_SETTINGS,
    { plan: { thinking: "medium" }, run: { model: "vm/deep" } },
    { plan: { model: "vm/flash" }, items: { role: "reviewer" } },
  );
  assert.deepEqual(reports, []);
  assert.deepEqual(settings.plan, { model: "vm/flash", thinking: "medium" });
  assert.deepEqual(settings.run, { model: "vm/deep", thinking: "low" });
  assert.deepEqual(settings.items, { role: "reviewer", thinking: "high" });
});

test("naming a model drops the role, and a role drops the model", () => {
  const { settings } = resolveSettings(DEFAULT_SETTINGS, undefined, {
    gateReview: { model: "vm/flash" },
    plan: { role: "reviewer" },
  });
  assert.deepEqual(settings.gateReview, { model: "vm/flash" });
  assert.deepEqual(settings.plan, { role: "reviewer", thinking: "high" });
});

test("an invalid value falls back and is reported, never thrown", () => {
  const { settings, reports } = resolveSettings(DEFAULT_SETTINGS, undefined, {
    judge: { thinking: "maxx" },
    plan: { model: "deepseek" },
    run: { role: "Builder Deep" },
    music: { model: "vm/flash" },
    guide: "vm/flash",
  });
  assert.deepEqual(settings.judge, DEFAULT_SETTINGS.judge);
  assert.deepEqual(settings.plan, DEFAULT_SETTINGS.plan);
  assert.deepEqual(settings.run, DEFAULT_SETTINGS.run);
  assert.deepEqual(settings.guide, DEFAULT_SETTINGS.guide);
  assert.deepEqual(
    reports.map((report) => `${report.key}.${report.field}`),
    ["judge.thinking", "plan.model", "run.role", "music.model", "guide.model"],
  );
});

test("model references and levels are the shapes the rest of the flow assumes", () => {
  assert.equal(isModelRef("vm/flash"), true);
  assert.equal(isModelRef("tensorx/deepseek/chat"), true);
  assert.equal(isModelRef("flash"), false);
  assert.equal(isModelRef("/flash"), false);
  assert.equal(isModelRef("vm/"), false);
  assert.equal(isModelRef(7), false);
  assert.equal(isLevel("high"), true);
  assert.equal(isLevel("highest"), false);
});

test("each step names its settings key and its kickoff", () => {
  assert.equal(settingKeyFor("plan", false), "plan");
  assert.equal(settingKeyFor("plan", true), "planQuick");
  assert.equal(settingKeyFor("run", false), "run");
  assert.equal(settingKeyFor("guide", false), "guide");
  assert.equal(settingKeyFor("brief", false), undefined);
  assert.equal(settingKeyFor("approve", false), undefined);
  assert.equal(settingKeyFor("done", false), undefined);

  assert.equal(kickoffFor("brief", "/p"), "/skill:flow-brief /p");
  assert.equal(kickoffFor("plan", "/p"), "/skill:flow-plan /p");
  assert.equal(kickoffFor("plan", "/p", true), "/skill:flow-plan /p --quick");
  assert.equal(kickoffFor("run", "/p"), "/skill:flow-run /p");
  assert.equal(kickoffFor("guide", "/p"), "/skill:flow-guide /p");
  assert.equal(kickoffFor("approve", "/p"), undefined);
  assert.equal(kickoffFor("done", "/p"), undefined);
  assert.equal(STEPS.length, 6);
});

test("the example handoff carries every required section", () => {
  for (const heading of [
    "# A CSV export",
    "## Mission",
    "## Smallest version",
    "Not building:",
    "## Scope",
    "## Context",
    "## Locked decisions",
    "### Yours",
    "### Defaults",
    "### Mechanism uncertain",
    "## Contracts",
    "## Work items",
    "## Budget",
    "## Stops",
    "## Review focus",
    "## Open questions",
    "## Amendments",
  ]) {
    assert.ok(example.includes(`${heading}\n`) || example.includes(heading), `missing ${heading}`);
  }
});

/** Each top-level bullet with its continuation lines joined, as the parser reads one. */
const bullets = (text: string) => {
  const joined: string[] = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("- ")) joined.push(line);
    else if (line.startsWith("  ") && joined.length > 0)
      joined[joined.length - 1] += ` ${line.trim()}`;
  }
  return joined;
};

test("the example's decisions, items and budget follow the grammar", () => {
  const lines = bullets(example);
  const decisions = lines
    .map((line) => /^- ([UD])(\d+) /.exec(line))
    .filter((match) => match !== null)
    .map((match) => match[1] + match[2]);
  assert.deepEqual(decisions, ["U1", "U2", "D1", "D2", "D3"]);
  const contracts = lines
    .map((line) => /^- (C\d+) ([^:]+): .+ Why: .+$/.exec(line))
    .filter((match) => match !== null)
    .map((match) => match[1]);
  assert.deepEqual(contracts, ["C1"]);

  const items = [...example.matchAll(/^### ((?:G|A|S)\d+) (.+)$/gm)].map((m) => ({
    id: m[1],
    title: m[2],
  }));
  assert.deepEqual(
    items.map((item) => item.id),
    ["G0", "A1", "S1"],
  );
  for (const item of items) assert.match(item.id, ITEM_ID);
  const spike = items.find((item) => item.id === "S1");
  assert.match(spike?.title ?? "", /\(spike, timebox \d+\)$/);
  assert.match(example, /^- Why: .+$/m);

  for (const field of [
    "Blocked by:",
    "Owns:",
    "New:",
    "Tier: ",
    "Outcome:",
    "Acceptance:",
    "Constraints:",
  ]) {
    assert.ok(example.includes(`- ${field}`), `no ${field} in the example`);
  }
  assert.equal([...example.matchAll(/^- Tier: (flash|deep)$/gm)].length, 3);
  // The marker may sit on a continuation line, so read the bullet joined.
  assert.ok(
    lines.some((line) => line.startsWith("- Acceptance:") && line.includes("(unverified)")),
    "an acceptance marked (unverified)",
  );

  const budget = [
    ...example.matchAll(/^- (New files|New abstractions|Lines|Cost cap|Concurrency): (.+)$/gm),
  ];
  assert.deepEqual(
    budget.map((match) => match[1]),
    ["New files", "New abstractions", "Lines", "Cost cap", "Concurrency"],
  );
  assert.match(example, /^- Cost cap: \$\d+$/m);
  assert.match(example, /^- Q1 .+$/m);
});

test("the grammar document is shipped beside the parser", () => {
  const format = readFileSync(new URL("./handoff-format.md", import.meta.url), "utf8");
  assert.match(format, /handoff-example\.md/);
  for (const required of [
    "## Mission",
    "## Smallest version",
    "## Work items",
    "## Budget",
    "## Stops",
  ]) {
    assert.ok(format.includes(required), `the grammar does not require ${required}`);
  }
});
