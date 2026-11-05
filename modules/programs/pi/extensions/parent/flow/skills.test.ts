/**
 * G0's guard on the flow skills: every `skills/<name>/SKILL.md` under the
 * parent package carries the frontmatter pi needs and stays out of the model's
 * skill catalogue. Parent-shipped skills reach subagent children too, so
 * `disable-model-invocation` is not a preference here.
 */
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const root = new URL("./skills/", import.meta.url);
const prose = (name: string): string =>
  readFileSync(new URL(`${name}/SKILL.md`, root), "utf8").replace(/\s+/g, " ");
const flowDocs = readFileSync(
  new URL("../../../../../../docs/flow.md", import.meta.url),
  "utf8",
).replace(/\s+/g, " ");

const names = readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

/** The frontmatter pi reads: `key: value` lines between the two `---` fences. */
const frontmatter = (text: string): Record<string, string> => {
  const lines = text.split("\n");
  if (lines[0]?.trim() !== "---") throw new Error("no frontmatter fence");
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === "---");
  if (end < 0) throw new Error("unterminated frontmatter");
  const fields: Record<string, string> = {};
  for (const line of lines.slice(1, end)) {
    const at = line.indexOf(":");
    if (at <= 0) throw new Error(`not a field: ${line}`);
    fields[line.slice(0, at).trim()] = line.slice(at + 1).trim();
  }
  return fields;
};

test("the four flow skills are shipped", () => {
  assert.deepEqual(names, ["flow-brief", "flow-guide", "flow-plan", "flow-run"]);
});

for (const name of names) {
  test(`${name} is a valid, hidden skill`, () => {
    const text = readFileSync(new URL(`${name}/SKILL.md`, root), "utf8");
    const fields = frontmatter(text);
    assert.equal(fields.name, name);
    assert.ok((fields.description ?? "").length > 20, "a description the command list can show");
    assert.equal(fields["disable-model-invocation"], "true");
    assert.ok(text.split("\n").length > 3, "a body, not just frontmatter");
  });
}

test("flow-run removes item artefacts before closing its worktree", () => {
  const text = prose("flow-run");
  assert.match(text, /Read the item's report, then delete `\.handoff-report\.md`/);
  assert.match(
    text,
    /every untracked artefact the item left, including `\.flow-logs\/` and other logs/,
  );
  assert.match(text, /Confirm `git status --porcelain` is empty before closing the worktree/);
});

test("straight mode still honours explicit and safety stops", () => {
  const text = prose("flow-run");
  assert.match(
    text,
    /A mode governs gates and deviations; the plan's explicit `## Stops` and the safety stops below apply in every mode\./,
  );
  assert.match(
    flowDocs,
    /A mode governs gates and deviations; the plan's explicit `## Stops` and `flow-run`'s safety stops apply in every mode\./,
  );
  assert.doesNotMatch(flowDocs, /`straight` never stops before the final report/);
});

test("flow-run carries only open questions no Amendment answers", () => {
  const text = prose("flow-run");
  assert.equal(text.match(/Open questions with no Amendment answering them/g)?.length, 2);
});
