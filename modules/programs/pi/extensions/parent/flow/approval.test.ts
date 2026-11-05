/**
 * A2's approval tests (C5, D13): the page's content and the three rewrites it
 * lands as, the dialogs a host without a terminal gets, and the overlay driven
 * by keys — including that enter on the row it opens on approves, which is what
 * a scenario can press blind.
 */
import assert from "node:assert/strict";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import { visibleWidth } from "@earendil-works/pi-tui";
import { ApprovalOverlay, approve } from "./approval.ts";
import {
  amendmentEntries,
  appendAmendments,
  applyPage,
  approvalBlocks,
  approvalMarkdown,
  initialPage,
  type PageState,
  rewriteTiers,
  tierEdits,
  today,
} from "./approval-view.ts";
import {
  DEFAULT_SETTINGS,
  type Flow,
  type JudgeHandoffVerdict,
  type ParsedHandoff,
  type ResolvedSettings,
  resolveSettings,
} from "./contracts.ts";
import { parseHandoff } from "./handoff.ts";

const exampleText = () => readFileSync(new URL("./handoff-example.md", import.meta.url), "utf8");

const parse = (text: string): ParsedHandoff => {
  const result = parseHandoff(text);
  assert.ok(result.ok, `the example must parse: ${JSON.stringify(result)}`);
  return result.handoff;
};

const handoff = parse(exampleText());

const verdict: JudgeHandoffVerdict = {
  mode: "deviation",
  run: { model: "vm/deep", thinking: "high" },
  tiers: { G0: "deep" },
  finalReview: "reviewer-deep",
  reasons: ["G0 is the writer everything else leans on"],
  cost: 0,
};

/** The flow the conductor hands the page: the verdict already merged into its settings. */
const flow = (over: Partial<Flow> = {}): Flow => ({
  v: 1,
  slug: "export",
  planDir: "/home/owner/.local/share/agents/app/plans/export",
  repoMain: "/home/owner/app",
  base: "main",
  branch: "export",
  step: "plan",
  mode: verdict.mode,
  quick: false,
  settings: { run: { model: verdict.run.model, thinking: verdict.run.thinking } },
  steps: [],
  judge: [],
  ...over,
});

/** The settings a flow resolves to, as the conductor hands them to the page. */
const resolved = (subject: Flow = flow()): ResolvedSettings =>
  resolveSettings(DEFAULT_SETTINGS, undefined, subject.settings).settings;

const settings: ResolvedSettings = resolved();

const page = (over: Partial<PageState> = {}): PageState => ({
  ...initialPage(flow(), handoff, verdict, resolved()),
  ...over,
});

/** A plan directory holding the example handoff, so the page can rewrite it. */
const scratch = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "flow-approval-"));
  copyFileSync(new URL("./handoff-example.md", import.meta.url), join(dir, "HANDOFF.md"));
  return dir;
};

const tierLineOf = (text: string, id: string): number => {
  const item = parse(text).items.find((candidate) => candidate.id === id);
  assert.ok(item, `no item ${id}`);
  return item.tierLine;
};

test("the page opens on the judge's mode, run model and tiers", () => {
  const opened = initialPage(flow(), handoff, verdict, resolved());
  assert.equal(opened.mode, "deviation");
  assert.equal(opened.settings.run.target, "vm/deep");
  assert.equal(opened.settings.run.thinking, "high");
  assert.equal(opened.settings.finalReview.target, "reviewer-deep");
  assert.equal(opened.settings.items.deep, "builder-deep");
  assert.equal(opened.tiers.G0, "deep");
  // An item the judge left alone keeps what the plan says.
  assert.equal(opened.tiers.A1, "flash");
  assert.deepEqual(opened.answers, {});
});

test("an owner value in FLOW.json wins over the judge's suggestion", () => {
  const own = flow({ settings: { run: { model: "vm/flash", thinking: "low" } }, mode: "straight" });
  const opened = initialPage(own, handoff, verdict, resolved(own));
  assert.equal(opened.mode, "straight");
  assert.equal(opened.settings.run.target, "vm/flash");
  assert.equal(opened.settings.run.thinking, "low");
});

test("approving writes the mode and only the settings the owner changed", () => {
  const opened = page();
  const edited = structuredClone(opened);
  edited.mode = "gated";
  edited.settings.finalReview.target = "reviewer";
  const { flow: next, reports } = applyPage(flow(), opened, edited);
  assert.deepEqual(reports, []);
  assert.equal(next.mode, "gated");
  // Exactly the one edit is added; nothing the owner left alone is frozen.
  assert.deepEqual(next.settings, { ...flow().settings, finalReview: { role: "reviewer" } });

  // A run model and a thinking level land on what the flow already held.
  edited.settings.run.target = "vm/flash";
  edited.settings.items.thinking = "medium";
  edited.settings.items.deep = "reviewer-deep";
  const more = applyPage(flow(), opened, edited).flow;
  assert.deepEqual(more.settings.run, { model: "vm/flash", thinking: "high" });
  assert.deepEqual(more.settings.items, { deep: "reviewer-deep", thinking: "medium" });
  assert.equal(more.settings.guide, undefined);

  // A model typed into a role row is refused: the row spawns a role, so the
  // model would sit where nothing reads it (see `resolveSettings`).
  const asModel = structuredClone(opened);
  asModel.settings.finalReview.target = "vm/deep";
  const roleEdit = applyPage(flow(), opened, asModel);
  assert.equal(roleEdit.flow.settings.finalReview, undefined, "a model was written for a role");
  assert.deepEqual(
    roleEdit.reports.map((entry) => `${entry.key}.${entry.field}`),
    ["finalReview.model"],
  );
});

test("an edited value resolveSettings would refuse is reported", () => {
  const opened = page();
  const edited = structuredClone(opened);
  edited.settings.run.target = "frontier";
  const { reports } = applyPage(flow(), opened, edited);
  assert.deepEqual(
    reports.map((entry) => `${entry.key}.${entry.field}`),
    ["run.model"],
  );
});

test("the gate reviewer's role locks its thinking, so the page offers no level for it", () => {
  const rows = approvalBlocks(flow(), handoff, page(), settings).flatMap((block) =>
    block.kind === "row" ? [block.row] : [],
  );
  assert.ok(rows.some((row) => row.kind === "setting" && row.key === "gateReview"));
  assert.ok(!rows.some((row) => row.kind === "settingThinking" && row.key === "gateReview"));
  assert.ok(rows.some((row) => row.kind === "settingThinking" && row.key === "finalReview"));
});

test("the page says the plan's stops apply in every mode, straight included", () => {
  const markdown = approvalMarkdown(
    approvalBlocks(flow(), handoff, page({ mode: "straight" }), settings),
  );
  assert.doesNotMatch(markdown, /never stops/);
  assert.match(markdown, /Mode — straight — logs deviations and continues to the final report/);
  assert.match(markdown, /## Stops and flow-run's safety stops apply in every mode/);
});

test("only the tiers the owner moved are rewritten, and only their own line", () => {
  // G0 takes the judge's deep, the owner moves A1 up, and S1 keeps what the plan says.
  const opened = initialPage(flow(), handoff, verdict, resolved());
  const edited = page({ tiers: { ...opened.tiers, A1: "deep" } });
  const edits = tierEdits(handoff, opened, edited);
  assert.deepEqual(
    edits.map((edit) => edit.tier),
    ["deep"],
  );
  const before = exampleText();
  const after = rewriteTiers(before, edits);
  const start = before.split("\n");
  const end = after.split("\n");
  assert.equal(start.length, end.length);
  const changed = start.flatMap((line, index) => (line === end[index] ? [] : [index + 1]));
  assert.deepEqual(
    changed,
    edits.map((edit) => edit.line),
  );
  assert.equal(
    end[tierLineOf(before, "G0") - 1],
    "- Tier: flash",
    "the judge's suggestion was written as the owner's move",
  );
  assert.equal(end[tierLineOf(before, "A1") - 1], "- Tier: deep");
  assert.equal(end[tierLineOf(before, "S1") - 1], "- Tier: flash", "an unmoved tier was rewritten");
  // Everything else still parses, so the file is a plan the run can read.
  parse(after);
});

test("a tier line that is no longer a Tier: bullet is refused rather than guessed", () => {
  const before = exampleText();
  const line = tierLineOf(before, "G0");
  const broken = before
    .split("\n")
    .map((text, index) => (index + 1 === line ? "- Tier: whatever" : text))
    .join("\n");
  assert.throws(
    () => rewriteTiers(broken, [{ line, tier: "deep" }]),
    /not a "- Tier: flash\|deep"/,
  );
  assert.throws(() => rewriteTiers(before, [{ line: 10_000, tier: "deep" }]), /no line 10000/);
});

test("an answer appends one dated Amendments entry and rewrites nothing else", () => {
  const answered = page({ answers: { Q1: "  the filename is report-<from>-<to>.csv  " } });
  const entries = amendmentEntries(handoff, answered, "2026-03-09");
  assert.deepEqual(entries, [
    "- 2026-03-09, owner, approval page: Q1 answered: the filename is report-<from>-<to>.csv",
  ]);
  const before = exampleText();
  const after = appendAmendments(before, entries);
  const lines = after.split("\n");
  const beforeLines = before.split("\n");
  // The original file is a prefix: nothing already written is rewritten.
  assert.deepEqual(lines.slice(0, beforeLines.length - 1), beforeLines.slice(0, -1));
  assert.equal(lines.filter((line) => /^##\s+Amendments$/.test(line)).length, 1);
  assert.equal(after.trimEnd().split("\n").at(-1), entries[0]);
  parse(after);
});

test("an answer on a plan with no Amendments section creates one", () => {
  const without = exampleText()
    .replace(/## Amendments[\s\S]*$/, "")
    .trimEnd();
  const after = appendAmendments(without, ["- 2026-03-09, owner, approval page: Q1 answered: yes"]);
  assert.match(after, /## Amendments\n\n- 2026-03-09, owner, approval page: Q1 answered: yes\n$/);
  assert.equal(parse(after).amendments, "- 2026-03-09, owner, approval page: Q1 answered: yes");
});

test("no answers and no moved tiers leave HANDOFF.md untouched", () => {
  const before = exampleText();
  const unchanged = appendAmendments(
    rewriteTiers(before, []),
    amendmentEntries(handoff, page(), today()),
  );
  assert.equal(unchanged, before);
});

test("APPROVAL.md lists every item, its blocker, its paths, and flags each unverified acceptance", () => {
  const markdown = approvalMarkdown(approvalBlocks(flow(), handoff, page(), settings));
  for (const item of handoff.items) assert.ok(markdown.includes(item.id), `no ${item.id}`);
  for (const item of handoff.items)
    assert.ok(markdown.includes(item.title), `no title for ${item.id}`);
  assert.ok(markdown.includes("Blocked by: G0"), "the button's blocker is not shown");
  assert.ok(markdown.includes("Blocked by: none"), "an unblocked item does not say none");
  assert.ok(markdown.includes("app/report/export.ts"), "the writer's path is not shown");
  // A1's acceptance has never been run, so the page says so; G0's is run.
  const unverified = markdown
    .split("\n")
    .filter((line) => line.includes("Acceptance") && line.includes("(unverified)"));
  assert.equal(unverified.length, 1);
  assert.match(unverified[0], /pnpm test:e2e report/);
  const writer = markdown
    .split("\n")
    .find((line) => line.includes("Acceptance") && line.includes("pnpm test app"));
  assert.ok(writer, "the writer's acceptance is missing");
  assert.ok(!writer.includes("unverified"), "a run acceptance is flagged as unverified");
  // What the run may stop on, and what it may cost, are both on the page.
  assert.ok(markdown.includes("G0: the owner reads the writer's interface"));
  assert.ok(markdown.includes("Cost cap: $2"));
  assert.ok(markdown.includes("Q1 Does the export need a filename"));
});

test("a host without a terminal gets APPROVAL.md and the select's answer", async () => {
  const dir = scratch();
  const asked: string[][] = [];
  const notes: string[] = [];
  const ctx = {
    mode: "json",
    ui: {
      select: async (_title: string, options: string[]) => {
        asked.push(options);
        return "approve";
      },
      input: async (title: string) => {
        notes.push(title);
        return undefined;
      },
      notify: () => undefined,
      custom: () => undefined,
    },
  } as unknown as ExtensionCommandContext;
  const pi = { getSettings: () => ({}) } as unknown as ExtensionAPI;

  const result = await approve(pi, ctx, flow({ planDir: dir }), handoff, verdict);
  assert.equal(result.kind, "approve");
  if (result.kind !== "approve") return;
  assert.deepEqual(asked, [["approve", "send back", "cancel"]]);
  assert.deepEqual(notes, []);

  // The page's own content is on disk next to the plan.
  const approval = readFileSync(join(dir, "APPROVAL.md"), "utf8");
  for (const item of handoff.items)
    assert.ok(approval.includes(item.id), `APPROVAL.md has no ${item.id}`);
  assert.match(approval, /# Approval: export/);

  // FLOW.json carries the mode and the run settings the page showed.
  const written = JSON.parse(readFileSync(join(dir, "FLOW.json"), "utf8"));
  assert.equal(written.mode, verdict.mode);
  assert.deepEqual(written.settings.run, verdict.run);

  // The judge's tier was pre-selected and approved, so it landed in the plan.
  const edited = readFileSync(join(dir, "HANDOFF.md"), "utf8");
  assert.equal(edited.split("\n")[tierLineOf(exampleText(), "G0") - 1], "- Tier: deep");
});

test("a send-back on a host without a terminal carries the note it asked for", async () => {
  const dir = scratch();
  const ctx = {
    mode: "rpc",
    ui: {
      select: async () => "send back",
      input: async () => "split A1 into the button and its test",
      notify: () => undefined,
      custom: () => undefined,
    },
  } as unknown as ExtensionCommandContext;
  const pi = { getSettings: () => ({}) } as unknown as ExtensionAPI;
  const result = await approve(pi, ctx, flow({ planDir: dir }), handoff, verdict);
  assert.deepEqual(result, { kind: "back", note: "split A1 into the button and its test" });
});

test("a dismissed select cancels, and an empty note with it", async () => {
  const dir = scratch();
  const build = (
    select: () => Promise<string | undefined>,
    input: () => Promise<string | undefined>,
  ) =>
    ({
      mode: "json",
      ui: { select, input, notify: () => undefined, custom: () => undefined },
    }) as unknown as ExtensionCommandContext;
  const pi = { getSettings: () => ({}) } as unknown as ExtensionAPI;
  const dismissed = await approve(
    pi,
    build(
      async () => undefined,
      async () => undefined,
    ),
    flow({ planDir: dir }),
    handoff,
    verdict,
  );
  assert.deepEqual(dismissed, { kind: "cancel" });
  const empty = await approve(
    pi,
    build(
      async () => "send back",
      async () => "   ",
    ),
    flow({ planDir: dir }),
    handoff,
    verdict,
  );
  assert.deepEqual(empty, { kind: "cancel" });
});

// ── the overlay ─────────────────────────────────────────────────────────────

/** Every style as a pass-through: the assertions then read what the owner sees. */
const theme = {
  fg: (_color: string, text: string) => text,
  bold: (text: string) => text,
} as unknown as Theme;

type Drawn = { kind: string; note?: string; page: PageState };

/** One overlay driven by keys, and the frame it leaves behind. */
const drive = (keys: string[], options: { rows?: number; width?: number; at?: PageState } = {}) => {
  let repaints = 0;
  const results: Drawn[] = [];
  const opened = options.at ?? page();
  const overlay = new ApprovalOverlay(
    { rows: options.rows ?? 40, requestRender: () => (repaints += 1) },
    theme,
    { flow: flow(), handoff, settings },
    opened,
    (result) => results.push(result as Drawn),
  );
  const first = overlay.render(options.width ?? 120);
  for (const key of keys) overlay.handleInput(key);
  return {
    overlay,
    page: opened,
    results,
    first,
    repaints,
    render: () => overlay.render(options.width ?? 120),
  };
};

test("the page opens at its top on approve, and enter approves", () => {
  const drawn = drive([]);
  const frame = drawn.first.join("\n");
  // It opens where it is read: the mission and the run's mode, not the buttons.
  assert.match(frame, /Approval: export/);
  assert.match(frame, /The dashboard prints a table/);
  assert.match(
    frame,
    /Mode {2}deviation — self-checks ordinary gates and stops only on a deviation/,
  );
  // The cursor is on approve, one jump away, and the items are another.
  assert.match(drive(["a"]).render().join("\n"), /▸ Approve and start the run/);
  const items = drive(["t"], { width: 160 }).render().join("\n");
  for (const item of handoff.items)
    assert.ok(items.includes(item.id), `the frame has no ${item.id}`);
  // Nothing else happened by merely drawing it.
  assert.deepEqual(drawn.results, []);

  const approved = drive(["\r"]);
  assert.equal(approved.results.length, 1);
  assert.equal(approved.results[0].kind, "approve");
  assert.equal(approved.results[0].page.mode, verdict.mode);
});

test("every frame fits the width it is given", () => {
  for (const width of [60, 100, 160]) {
    for (const line of drive([], { width, rows: 30 }).first) {
      assert.ok(
        visibleWidth(line) <= width,
        `a ${visibleWidth(line)}-wide line at ${width}: ${line}`,
      );
    }
  }
});

test("m takes the mode row and the arrows cycle it", () => {
  const drawn = drive(["m", "\u001b[C"]);
  assert.equal(drawn.page.mode, "straight");
  drive(["m", "\u001b[C"]).render();
  const cycled = drive(["m", "\u001b[D"]);
  assert.equal(cycled.page.mode, "gated");
  // Enter on a cycle row advances it like the right arrow.
  assert.equal(drive(["m", "\r"]).page.mode, "straight");
});

test("r edits the run model as text, and an empty edit keeps the value", () => {
  const typed = drive(["r", "\r", ..."vm/frontier".split(""), "\r"]);
  assert.equal(typed.page.settings.run.target, "vm/frontier");
  assert.deepEqual(typed.results, [], "committing a model must not end the page");

  // Enter twice opens the field and submits it empty: the value stays.
  const twice = drive(["r", "\r", "\r"]);
  assert.equal(twice.page.settings.run.target, "vm/deep");
  // f is the final reviewer; up past the gate reviewer and the items' level is the deep role.
  const deep = drive(["f", "k", "k", "k", "\r", "\r"]);
  assert.equal(deep.page.settings.items.deep, "builder-deep");

  // Escape in the field drops the edit and leaves the page open.
  const dropped = drive(["r", "\r", ..."vm/flash".split(""), "\u001b"]);
  assert.equal(dropped.page.settings.run.target, "vm/deep");
  assert.deepEqual(dropped.results, []);
});

test("a refused value keeps the page open on approve and says which", () => {
  const invalid = drive(["r", "\r", ..."frontier".split(""), "\r", "a", "\r"]);
  assert.deepEqual(invalid.results, [], "an invalid model approved the page");
  assert.match(invalid.render().join("\n"), /run\.model = "frontier"/);
  // Fixing it lets the same keys approve.
  for (const key of ["r", "\r", ..."vm/flash".split(""), "\r", "a", "\r"])
    invalid.overlay.handleInput(key);
  const after: Drawn[] = invalid.results;
  assert.equal(after[0]?.kind, "approve");
});

test("a model typed into a role row keeps the page open too", () => {
  // `f` is the final reviewer's row; the page takes a role there, so a model is
  // an edit it cannot approve, and the default role stays.
  const refused = drive(["f", "\r", ..."vm/deep".split(""), "\r", "a", "\r"]);
  assert.deepEqual(refused.results, [], "a model in a role row approved the page");
  assert.match(refused.render().join("\n"), /finalReview\.model = "vm\/deep"/);
});

test("f edits the final reviewer role and its thinking row cycles", () => {
  const typed = drive(["f", "\r", ..."reviewer".split(""), "\r"]);
  assert.equal(typed.page.settings.finalReview.target, "reviewer");
  assert.deepEqual(typed.results, []);
  assert.match(typed.render().join("\n"), /Final review role {2}reviewer/);

  const cycled = drive(["f", "j", "\u001b[C"]);
  assert.equal(cycled.page.settings.finalReview.thinking, "xhigh");
});

test("a HANDOFF.md changed under the page is not overwritten", async () => {
  const dir = scratch();
  const path = join(dir, "HANDOFF.md");
  const original = readFileSync(path, "utf8");
  const notes: string[] = [];
  let reads = 0;
  const read = (file: string) => {
    reads += 1;
    return reads === 1 ? readFileSync(file, "utf8") : `${original}\n<!-- planner edit -->\n`;
  };
  const ctx = {
    mode: "json",
    ui: {
      select: async () => "approve",
      input: async () => undefined,
      notify: (text: string) => notes.push(text),
      custom: () => undefined,
    },
  } as unknown as ExtensionCommandContext;
  const pi = { getSettings: () => ({}) } as unknown as ExtensionAPI;
  const result = await approve(pi, ctx, flow({ planDir: dir }), handoff, verdict, read);
  assert.deepEqual(result, { kind: "cancel" });
  assert.equal(readFileSync(path, "utf8"), original, "the stale snapshot was written");
  assert.equal(existsSync(join(dir, "FLOW.json")), false);
  assert.match(notes.at(-1) ?? "", /changed under the approval page.*not applied/);
});

test("t cycles the first tier, and only that item's", () => {
  const drawn = drive(["t", "\u001b[C"]);
  assert.equal(drawn.page.tiers.G0, "flash");
  assert.equal(drawn.page.tiers.A1, "flash");
  assert.ok(drawn.render().join("\n").includes("tier: flash"));
});

test("q answers the first open question, and the answer shows on the page", () => {
  const drawn = drive(["q", "\r", ..."report-2026-03.csv".split(""), "\r"]);
  assert.equal(drawn.page.answers.Q1, "report-2026-03.csv");
  assert.deepEqual(drawn.results, []);
  assert.match(drawn.render().join("\n"), /report-2026-03\.csv/);
});

test("s sends back with the note that was typed, and refuses an empty one", () => {
  const empty = drive(["s", "\r", "\r"]);
  assert.deepEqual(empty.results, [], "an empty note ended the page");
  assert.match(empty.render().join("\n"), /needs a note/);

  const sent = drive(["s", "\r", ..."split A1".split(""), "\r"]);
  assert.equal(sent.results.length, 1);
  assert.equal(sent.results[0].kind, "back");
  assert.equal(sent.results[0].note, "split A1");
});

test("escape cancels and a decided page does not answer twice", () => {
  const drawn = drive(["\u001b"]);
  assert.equal(drawn.results.length, 1);
  assert.equal(drawn.results[0].kind, "cancel");
  // A key after the answer is not a second one.
  drawn.overlay.handleInput("\r");
  drawn.overlay.handleInput("a");
  assert.equal(drawn.results.length, 1);
});

test("the frame scrolls to the row the keys jumped to", () => {
  const drawn = drive(["q"], { rows: 14, width: 90 });
  const frame = drawn.render().join("\n");
  assert.match(frame, /Q1 Does the export need a filename/);
  // The hint stays on the frame whatever the scroll did.
  assert.match(frame, /esc cancel/);
});

test("the overlay approves a page it opened with, editing nothing else", () => {
  const answered = drive(["s", "\r", ..."no".split(""), "\r"], {
    at: page({ answers: { Q1: "kept" } }),
  });
  assert.equal(answered.results[0].kind, "back");
  assert.equal(answered.results[0].page.answers.Q1, "kept");
});

/** A terminal host whose overlay takes these keys, as pi's `custom` would hand them over. */
const tuiCtx = (keys: string[], notes: string[] = []) =>
  ({
    mode: "tui",
    ui: {
      notify: (text: string) => notes.push(text),
      select: async () => undefined,
      input: async () => undefined,
      custom: <T>(
        factory: (
          tui: unknown,
          theme: Theme,
          keybindings: unknown,
          done: (result: T) => void,
        ) => ApprovalOverlay,
      ) =>
        new Promise<T>((resolve) => {
          const overlay = factory(
            { terminal: { rows: 40 }, requestRender: () => undefined },
            theme,
            undefined,
            resolve,
          );
          overlay.render(120);
          for (const key of keys) overlay.handleInput(key);
        }),
    },
  }) as unknown as ExtensionCommandContext;

test("an approved page with one edit writes exactly that key to FLOW.json", async () => {
  const dir = scratch();
  const pi = { getSettings: () => ({}) } as unknown as ExtensionAPI;
  const keys = ["f", "\r", ..."reviewer".split(""), "\r", "a", "\r"];
  const result = await approve(pi, tuiCtx(keys), flow({ planDir: dir }), handoff, verdict);
  assert.equal(result.kind, "approve");
  const written = JSON.parse(readFileSync(join(dir, "FLOW.json"), "utf8"));
  assert.deepEqual(written.settings, { ...flow().settings, finalReview: { role: "reviewer" } });
});

test("a send-back writes no settings to FLOW.json", async () => {
  const dir = scratch();
  const pi = { getSettings: () => ({}) } as unknown as ExtensionAPI;
  const keys = ["f", "\r", ..."reviewer".split(""), "\r", "m", "\u001b[C"];
  const back = [...keys, "s", "\r", ..."split A1".split(""), "\r"];
  const result = await approve(pi, tuiCtx(back), flow({ planDir: dir }), handoff, verdict);
  assert.deepEqual(result, { kind: "back", note: "split A1" });
  assert.equal(existsSync(join(dir, "FLOW.json")), false, "a send-back wrote FLOW.json");

  const cancelled = await approve(
    pi,
    tuiCtx([...keys, "\u001b"]),
    flow({ planDir: dir }),
    handoff,
    verdict,
  );
  assert.deepEqual(cancelled, { kind: "cancel" });
  assert.equal(existsSync(join(dir, "FLOW.json")), false, "a cancel wrote FLOW.json");
});

test("a judge's tier the owner leaves alone is written on approve, not on send-back or cancel", async () => {
  for (const [answer, kind] of [
    ["send back", "back"],
    ["cancel", "cancel"],
  ] as const) {
    const dir = scratch();
    const before = readFileSync(join(dir, "HANDOFF.md"), "utf8");
    const ui = {
      select: async () => answer,
      input: async () => (kind === "back" ? "split it" : undefined),
      notify: () => undefined,
      custom: () => undefined,
    };
    const result = await approve(
      { getSettings: () => ({}) } as unknown as ExtensionAPI,
      { mode: "json", ui } as unknown as ExtensionCommandContext,
      flow({ planDir: dir }),
      handoff,
      verdict,
    );
    assert.equal(result.kind, kind);
    assert.equal(
      readFileSync(join(dir, "HANDOFF.md"), "utf8"),
      before,
      `${kind} wrote the judge's suggestion into the plan`,
    );
  }
});
