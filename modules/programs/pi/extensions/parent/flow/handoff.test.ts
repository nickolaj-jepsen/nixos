/**
 * A2's parser tests (C6): `handoff-example.md` parses with every field in place,
 * and each way a plan can be malformed comes back as an error naming its line —
 * which is all a refused approval can tell the planner.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parseHandoff } from "./handoff.ts";

const example = readFileSync(new URL("./handoff-example.md", import.meta.url), "utf8");

const linesOf = (text: string) => text.split("\n");

/** The example with one line replaced; throws when the line is not there, so a stale test cannot pass. */
const withLine = (text: string, find: string, replace: string): string => {
  const lines = linesOf(text);
  const at = lines.findIndex((line) => line.includes(find));
  assert.ok(at >= 0, `no line holding ${JSON.stringify(find)}`);
  lines[at] = replace;
  return lines.join("\n");
};

/** The example with one line removed. */
const withoutLine = (text: string, find: string): string => {
  const lines = linesOf(text);
  const at = lines.findIndex((line) => line.includes(find));
  assert.ok(at >= 0, `no line holding ${JSON.stringify(find)}`);
  lines.splice(at, 1);
  return lines.join("\n");
};

/** The example parsed, or the assertion that it parses. */
const parse = (text: string) => {
  const result = parseHandoff(text);
  assert.ok(result.ok, `expected a parse, got ${JSON.stringify(result)}`);
  return result.handoff;
};

/** The messages of a refused parse, one per line, and the lines they name. */
const refusal = (text: string) => {
  const result = parseHandoff(text);
  assert.equal(result.ok, false, "expected the plan to be refused");
  if (result.ok) throw new Error("unreachable");
  return result.errors;
};

const oneError = (text: string, pattern: RegExp) => {
  const errors = refusal(text);
  const found = errors.filter((error) => pattern.test(error.message));
  assert.equal(
    found.length,
    1,
    `expected one error matching ${pattern}, got ${JSON.stringify(errors)}`,
  );
  return found[0];
};

/** The 1-based line an error names, for asserting the line really holds what failed. */
const lineAt = (text: string, number: number) => linesOf(text)[number - 1];

test("the C6 example parses whole", () => {
  const handoff = parse(example);
  assert.match(handoff.mission, /^The dashboard prints a table/);
  assert.match(handoff.smallestVersion, /^One button on the existing report page/);
  assert.deepEqual(handoff.notBuilding, [
    "an export format picker;",
    "server-side exports of tables nobody has opened;",
    "a scheduled email of the export;",
    "any change to the table's own columns.",
  ]);
  assert.match(handoff.scope, /^In:/);
  assert.match(handoff.context, /^- Repo `example\/app`, base branch `main`/);
  assert.deepEqual(
    handoff.yours.map((decision) => decision.id),
    ["U1", "U2"],
  );
  assert.deepEqual(
    handoff.defaults.map((decision) => decision.id),
    ["D1", "D2"],
  );
  assert.deepEqual(
    handoff.uncertain.map((decision) => decision.id),
    ["D3"],
  );
  assert.match(handoff.yours[1].text, /^The button never waits on a network round trip\./);
  assert.deepEqual(
    handoff.contracts.map((contract) => contract.id),
    ["C1"],
  );
  assert.match(handoff.contracts[0].name, /toCsv/);
  assert.match(handoff.contracts[0].why, /the writer is the only part a test can pin/);
  assert.deepEqual(handoff.budget, {
    newFiles: 5,
    newAbstractions: 1,
    lines: 220,
    costCap: 2,
    concurrency: 2,
  });
  assert.equal(handoff.stops.length, 2);
  assert.match(handoff.stops[0], /^G0: the owner reads the writer/);
  assert.deepEqual(
    handoff.openQuestions.map((question) => question.id),
    ["Q1"],
  );
  assert.match(handoff.amendments, /^- 2026-03-01, owner: Q1 answered/);
  for (const heading of ["Mission", "Scope", "Work items", "Budget", "Review focus", "Amendments"])
    assert.ok(heading in handoff.sections, `no verbatim section for ${heading}`);
});

test("every item keeps its fields, its tier line and its flags", () => {
  const handoff = parse(example);
  assert.deepEqual(
    handoff.items.map((item) => item.id),
    ["G0", "A1", "S1"],
  );
  const [writer, button, spike] = handoff.items;
  assert.deepEqual(writer.blockedBy, []);
  assert.deepEqual(writer.owns, ["app/report/export.ts", "app/report/export.test.ts"]);
  assert.equal(writer.adds, "the CSV writer");
  assert.equal(writer.tier, "flash");
  assert.match(writer.outcome, /^`toCsv` exists/);
  assert.match(writer.acceptance, /^`pnpm test app\/report\/export\.test\.ts`/);
  assert.equal(writer.acceptanceUnverified, false);
  assert.equal(writer.spike, false);
  assert.equal(writer.why, undefined);

  // The example's second item runs its acceptance nowhere yet, and C6 flags that.
  assert.deepEqual(button.blockedBy, ["G0"]);
  assert.equal(button.acceptanceUnverified, true);

  // A spike carries what it buys; without it the box is not worth its time.
  assert.equal(spike.spike, true);
  assert.match(spike.title, /\(spike, timebox 30\)$/);
  assert.match(spike.why ?? "", /^a second copy of the column order/);

  // The tier line is where a rewrite lands, and it holds the value it parses.
  for (const item of handoff.items) {
    assert.match(lineAt(example, item.tierLine), /^- Tier: (flash|deep)$/);
    assert.equal(lineAt(example, item.tierLine), `- Tier: ${item.tier}`);
  }
  const tierLines = handoff.items.map((item) => item.tierLine);
  assert.deepEqual(
    tierLines,
    [...tierLines].sort((left, right) => left - right),
  );
});

test("a missing required section is refused at the top and names the section", () => {
  const errors = refusal(withoutLine(example, "## Budget"));
  const missing = errors.find((error) => error.message.includes("## Budget"));
  assert.ok(missing, `no error names ## Budget: ${JSON.stringify(errors)}`);
  assert.equal(missing.line, 1);
});

test("a malformed item field is refused at its own line", () => {
  const broken = withLine(example, "- Tier: flash", "- Tier: quick");
  const error = oneError(broken, /Tier: "quick" is not flash or deep/);
  assert.match(lineAt(broken, error.line), /^- Tier: quick$/);
});

test("a missing item field is refused at the item's heading", () => {
  const broken = withoutLine(example, "- Outcome: the report page shows one button");
  const error = oneError(broken, /item A1 has no "- Outcome:" bullet/);
  assert.match(lineAt(broken, error.line), /^### A1 /);
});

test("an item heading without a G, A or S ID is refused", () => {
  const broken = withLine(example, "### A1 The button", "### X1 The button");
  const error = oneError(broken, /item "X1" is not an ID/);
  assert.match(lineAt(broken, error.line), /^### X1 /);
});

test("a blocked-by that names no item in the plan is refused", () => {
  const broken = withLine(example, "- Blocked by: G0", "- Blocked by: G7");
  const error = oneError(broken, /blocked by G7, which this plan has no item for/);
  assert.match(lineAt(broken, error.line), /^- Blocked by: G7$/);
});

test("an item blocked by itself is refused", () => {
  const error = oneError(
    withLine(example, "- Blocked by: G0", "- Blocked by: A1"),
    /blocked by itself/,
  );
  assert.ok(error.line > 0);
});

test("a spike without its Why: is refused", () => {
  const broken = withoutLine(example, "a second copy of the column order");
  const error = oneError(broken, /spike S1 has no "- Why:" line/);
  assert.match(lineAt(broken, error.line), /^### S1 /);
});

test("a smallest version with nothing left out is refused", () => {
  let broken = withLine(example, "Not building:", "Not building:");
  for (const bullet of [
    "- an export format picker;",
    "- server-side exports",
    "- a scheduled email of the export;",
    "- any change to the table's own columns.",
  ])
    broken = withoutLine(broken, bullet);
  const error = oneError(broken, /Not building: needs at least one bullet/);
  assert.match(lineAt(broken, error.line), /^Not building:/);
});

test("a scope with no Out: is refused", () => {
  const broken = withLine(example, "Out: every other page", "Everywhere: every other page");
  oneError(broken, /## Scope needs an "Out:" line/);
});

test("a second ## section with the same heading is refused", () => {
  const broken = `${example}\n## Mission\n\na second mission\n`;
  const error = oneError(broken, /a second ## Mission section/);
  assert.match(lineAt(broken, error.line), /^## Mission$/);
});

test("an item owning nothing is refused at its Owns: line", () => {
  const unowned = example.replace(
    /- Owns:\n  - `app\/report\/export\.ts`, `app\/report\/export\.test\.ts`\n/,
    "- Owns:\n",
  );
  const error = oneError(unowned, /item G0's "- Owns:" is empty/);
  assert.match(lineAt(unowned, error.line), /^- Owns:$/);
});

test("an owns value without backticks still lists its paths", () => {
  const plain = example.replace(
    /  - `app\/report\/export\.ts`, `app\/report\/export\.test\.ts`\n/,
    "  app/report/export.ts, app/report/export.test.ts\n",
  );
  const handoff = parse(plain);
  assert.deepEqual(handoff.items[0].owns, ["app/report/export.ts", "app/report/export.test.ts"]);
});

test("a contract with no Why: is refused", () => {
  const broken = withLine(
    example,
    "Why: the writer is the only part a test can pin.",
    "It is good.",
  );
  const error = oneError(broken, /C1 has no "Why:" reason/);
  assert.ok(error.line > 0);
});

test("a budget bullet that is not a number is refused", () => {
  const broken = withLine(example, "- Lines: 220", "- Lines: about 220");
  oneError(broken, /Lines: .* does not start with a number/);
});

test("a missing budget bullet is refused at the section heading", () => {
  const broken = withoutLine(example, "- Concurrency: 2");
  const error = oneError(broken, /## Budget has no "- Concurrency:" bullet/);
  assert.match(lineAt(broken, error.line), /^## Budget$/);
});

test("every error carries a line, sorted top to bottom", () => {
  const broken = withoutLine(withLine(example, "- Tier: flash", "- Tier: quick"), "- Lines: 220");
  const errors = refusal(broken);
  assert.ok(errors.length >= 2, `expected several errors, got ${JSON.stringify(errors)}`);
  const numbers = errors.map((error) => error.line);
  assert.deepEqual(
    numbers,
    [...numbers].sort((left, right) => left - right),
  );
  for (const error of errors) {
    assert.ok(error.line >= 1, "an error with no line");
    assert.ok(error.message.length > 0, "an error with no message");
  }
});

test("a decision bullet under the wrong subsection is refused", () => {
  const broken = withLine(example, "- U1 CSV, not Excel.", "- D9 CSV, not Excel.");
  const error = oneError(broken, /a decision in ### Yours is U<n>, not D9/);
  assert.match(lineAt(broken, error.line), /^- D9 CSV/);
});

test("an item field that is not one of the seven is refused", () => {
  const broken = withLine(example, "- Outcome: `toCsv` exists", "- Results: `toCsv` exists");
  const error = oneError(broken, /"Results" is not an item field/);
  assert.match(lineAt(broken, error.line), /^- Results:/);
});
