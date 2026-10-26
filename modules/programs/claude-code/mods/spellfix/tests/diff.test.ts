import { expect, test } from "claude-code/testing";

import { applyEdits, wordDiff } from "../hooks/core";

const words = (runs: { text: string }[]) => runs.flatMap((r) => r.text.split(" ")).join(" ");

test("wordDiff keeps an unchanged string one run", () => {
  expect(wordDiff("the patch", "the patch")).toEqual([{ text: "the patch", kind: "same" }]);
});

test("wordDiff marks a swapped word removed then added", () => {
  expect(wordDiff("recieve", "receive")).toEqual([
    { text: "recieve", kind: "removed" },
    { text: "receive", kind: "added" },
  ]);
});

test("wordDiff keeps the words a reorder preserves", () => {
  const runs = wordDiff("I want you to the tests update", "I want you to update the tests");
  expect(runs[0]).toEqual({ text: "I want you to", kind: "same" });
  expect(JSON.stringify(runs)).toContain("update");
  expect(JSON.stringify(runs)).toContain("tests");
});

test("wordDiff's runs reconstruct both sides", () => {
  const cases: [string, string][] = [
    ["it very needy", 'it is very "needy"'],
    ["the agent should recieve the patch", "the agent should receive the patch"],
    ["a b c", "c b a"],
    ["nothing here", "completely different words entirely"],
    ["one", ""],
  ];
  for (const [old, next] of cases) {
    const runs = wordDiff(old, next);
    const kept = runs.filter((r) => r.kind !== "added").map((r) => r.text);
    const changed = runs.filter((r) => r.kind !== "removed").map((r) => r.text);
    expect(words(kept.map((text) => ({ text })))).toBe(words(old.trim() ? [{ text: old }] : []));
    expect(words(changed.map((text) => ({ text })))).toBe(
      words(next.trim() ? [{ text: next }] : []),
    );
  }
});

test("applyEdits replaces several spans by their original offsets", () => {
  const text = "teh agent will recieve teh patch";
  const edits = [
    { start: 0, end: 3, text: "the" },
    { start: 15, end: 22, text: "receive" },
    { start: 23, end: 26, text: "the" },
  ];
  expect(applyEdits(text, edits)).toBe("the agent will receive the patch");
});

test("applyEdits drops a splice that overlaps one already applied", () => {
  const text = "abcdef";
  expect(
    applyEdits(text, [
      { start: 1, end: 4, text: "X" },
      { start: 3, end: 5, text: "Y" },
    ]),
  ).toBe("aXef");
});

test("applyEdits with no splices returns the text unchanged", () => {
  expect(applyEdits("as it was", [])).toBe("as it was");
});
