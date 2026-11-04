/**
 * A6's tour without tuicr: the argv `/rv` has to be given for the seed to be
 * visible, the slug is parsed from what tuicr printed (never computed), and the
 * diff check that keeps a stop from being stored and never rendered.
 *
 * The seeding case runs a scripted runner, so every command the tool would spawn
 * is asserted here: the range, the headless start, the `Flow` author and the
 * anchor flags.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import type { TourSpec } from "./contracts.ts";
import {
  type Command,
  diffAnchors,
  parseSessionSlug,
  seedTour,
  stopProblem,
  type TourRunner,
  tourArgv,
  tourRv,
} from "./tour.ts";

/** What `git diff --unified=0` prints for a changed line, a new file and a deletion. */
const DIFF = [
  "diff --git a/a.ts b/a.ts",
  "index 1234567..89abcde 100644",
  "--- a/a.ts",
  "+++ b/a.ts",
  "@@ -1 +1 @@",
  "-export const value = 1;",
  "+export const value = 2;",
  "diff --git a/c.ts b/c.ts",
  "new file mode 100644",
  "index 0000000..abcdef0",
  "--- /dev/null",
  "+++ b/c.ts",
  "@@ -0,0 +1,3 @@",
  "+export const doubled = (n: number) => n * 2;",
  "+export const tripled = (n: number) => n * 3;",
  "+export const quadrupled = (n: number) => n * 4;",
  "diff --git a/gone.ts b/gone.ts",
  "deleted file mode 100644",
  "index abcdef0..0000000",
  "--- a/gone.ts",
  "+++ /dev/null",
  "@@ -1,2 +0,0 @@",
  "-export const gone = 1;",
  "-export const alsoGone = 2;",
  "",
].join("\n");

const FROM = "1ac82a9";
const BRANCH = "tour";
const REPO = "/work/repo";

const WHERE = { repoMain: REPO, branch: BRANCH, from: FROM };

/** tuicr 0.28.0's stderr on a headless start, then why it exited 1 (notes/tuicr.md §2). */
const STARTED = [
  `tuicr-session: pi-flow-research/origin@main/commits/${FROM}..413aef1`,
  "Error: No such device or address (os error 6)",
  "",
].join("\n");

const SPEC: TourSpec = {
  intro: "Read a.ts first: the value moves.",
  stops: [
    { file: "a.ts", line: 1, type: "note", body: "the new value" },
    { file: "c.ts", line: 1, endLine: 3, type: "praise", body: "the doubling helpers" },
  ],
};

/** A runner that answers from the script and keeps every command it was given. */
const scripted = (...answers: Command[]) => {
  const calls: { command: string; args: string[]; cwd: string }[] = [];
  const run: TourRunner = async (command, args, cwd) => {
    calls.push({ command, args, cwd });
    return answers.shift() ?? { code: 1, stdout: "", stderr: "no answer scripted" };
  };
  return { calls, run };
};

const ok = (stdout = ""): Command => ({ code: 0, stdout, stderr: "" });

test("D24 the tour's argv is the branch diff /rv opens", () => {
  assert.deepEqual(tourArgv(FROM, BRANCH), ["-r", `${FROM}..${BRANCH}`]);
  assert.equal(tourRv(FROM, BRANCH), `/rv -r ${FROM}..${BRANCH}`);
});

test("the slug comes from tuicr's stderr, not from the argv", () => {
  assert.equal(parseSessionSlug(STARTED), `pi-flow-research/origin@main/commits/${FROM}..413aef1`);
  // A run with nothing to review prints no slug, which is how the caller learns it.
  assert.equal(parseSessionSlug("Error: No changes to review\n"), undefined);
  assert.equal(parseSessionSlug(""), undefined);
  // Carriage returns and a second session line: the last one wins.
  assert.equal(parseSessionSlug("tuicr-session: one\r\ntuicr-session: two\r\n"), "two");
});

test("the diff's anchors are the lines each side offers", () => {
  const anchors = diffAnchors(DIFF);
  assert.deepEqual([...anchors.keys()], ["a.ts", "c.ts", "gone.ts"]);
  assert.deepEqual([...anchors.get("a.ts")!.new], [1]);
  assert.deepEqual([...anchors.get("a.ts")!.old], [1]);
  assert.deepEqual([...anchors.get("c.ts")!.new], [1, 2, 3]);
  assert.deepEqual([...anchors.get("c.ts")!.old], []);
  // A deletion keeps its path and its old lines, and offers no new one.
  assert.deepEqual([...anchors.get("gone.ts")!.old], [1, 2]);
  assert.deepEqual([...anchors.get("gone.ts")!.new], []);
});

test("a stop off the diff is named, a stop on it is not", () => {
  const anchors = diffAnchors(DIFF);
  assert.equal(stopProblem({ file: "a.ts", line: 1, type: "note", body: "" }, anchors), undefined);
  assert.equal(stopProblem({ file: "a.ts", type: "note", body: "" }, anchors), undefined);
  assert.equal(stopProblem({ type: "note", body: "" }, anchors), undefined);
  assert.equal(stopProblem({ file: "gone.ts", line: 1, side: "old", type: "note", body: "" }, anchors), undefined);

  const unknownFile = stopProblem({ file: "z.ts", line: 1, type: "note", body: "" }, anchors);
  assert.match(unknownFile ?? "", /z\.ts:1 is not a file of this diff/);
  const offDiff = stopProblem({ file: "a.ts", line: 9999, type: "note", body: "" }, anchors);
  assert.match(offDiff ?? "", /a\.ts:9999 is not a changed new line/);
  assert.match(offDiff ?? "", /1/);
  const wrongSide = stopProblem({ file: "gone.ts", line: 1, type: "note", body: "" }, anchors);
  assert.match(wrongSide ?? "", /not a changed new line/);
  const backwards = stopProblem({ file: "c.ts", line: 3, endLine: 1, type: "note", body: "" }, anchors);
  assert.match(backwards ?? "", /ends before it starts/);
  const farEnd = stopProblem({ file: "c.ts", line: 1, endLine: 40, type: "note", body: "" }, anchors);
  assert.match(farEnd ?? "", /c\.ts:40 is not a changed new line/);
  const noFile = stopProblem({ line: 2, type: "note", body: "" }, anchors);
  assert.match(noFile ?? "", /needs the file/);
});

test("a tour is seeded headlessly, in Flow's name, at the diff's lines", async () => {
  const { calls, run } = scripted(
    ok(DIFF),
    { code: 1, stdout: "", stderr: STARTED },
    ok(),
    ok(),
    ok(),
  );
  const seeded = await seedTour(run, WHERE, SPEC);
  assert.ok(seeded.ok, seeded.ok ? "" : seeded.error);
  assert.equal(seeded.added, 3);
  assert.deepEqual(seeded.tour, {
    slug: `pi-flow-research/origin@main/commits/${FROM}..413aef1`,
    argv: ["-r", `${FROM}..${BRANCH}`],
    cwd: REPO,
    rv: `/rv -r ${FROM}..${BRANCH}`,
  });

  assert.deepEqual(calls.map((call) => call.command), ["git", "tuicr", "tuicr", "tuicr", "tuicr"]);
  assert.deepEqual(calls[0]?.args.slice(-2), [`${FROM}..${BRANCH}`, "--"]);
  for (const call of calls) assert.equal(call.cwd, REPO);
  // The headless start is the argv /rv will use, plus the flag that skips the
  // network; the stored argv stays exactly what /rv runs.
  assert.deepEqual(calls[1]?.args, ["tui", "-r", `${FROM}..${BRANCH}`, "--no-update-check"]);

  const intro = calls[2]?.args ?? [];
  assert.deepEqual(intro.slice(0, 2), ["review", "add"]);
  assert.equal(intro[intro.indexOf("--username") + 1], "Flow");
  assert.equal(intro[intro.indexOf("--type") + 1], "note");
  assert.equal(intro.at(-1), SPEC.intro);
  assert.ok(!intro.includes("--target-file"), "a review-level comment has no file");

  const first = calls[3]?.args ?? [];
  assert.equal(first[first.indexOf("--target-file") + 1], "a.ts");
  assert.equal(first[first.indexOf("--line") + 1], "1");
  assert.equal(first[first.indexOf("--side") + 1], "new");
  assert.equal(first.at(-1), "the new value");
  assert.ok(!first.includes("--end-line"));

  const second = calls[4]?.args ?? [];
  assert.equal(second[second.indexOf("--end-line") + 1], "3");
  assert.equal(second[second.indexOf("--type") + 1], "praise");
});

test("a stop outside the diff is refused before tuicr is started", async () => {
  const { calls, run } = scripted(ok(DIFF));
  const seeded = await seedTour(run, WHERE, {
    intro: "Read it.",
    stops: [{ file: "a.ts", line: 9999, type: "note", body: "drifted" }],
  });
  assert.equal(seeded.ok, false);
  assert.match(seeded.ok ? "" : seeded.error, /stop 1: a\.ts:9999 is not a changed new line/);
  assert.deepEqual(calls.map((call) => call.command), ["git"]);
});

test("a headless start that prints no slug is an error, not a tour", async () => {
  const { calls, run } = scripted(ok(DIFF), {
    code: 1,
    stdout: "",
    stderr: "Error: No changes to review\n",
  });
  const seeded = await seedTour(run, WHERE, SPEC);
  assert.equal(seeded.ok, false);
  assert.match(seeded.ok ? "" : seeded.error, /No changes to review/);
  assert.deepEqual(calls.map((call) => call.command), ["git", "tuicr"]);
});

test("a range that changes no file has nothing to tour", async () => {
  const { calls, run } = scripted(ok(""));
  const seeded = await seedTour(run, WHERE, SPEC);
  assert.equal(seeded.ok, false);
  assert.match(seeded.ok ? "" : seeded.error, /nothing to tour/);
  assert.deepEqual(calls.map((call) => call.command), ["git"]);
});

test("a comment tuicr refuses is reported with the session that holds the others", async () => {
  const { run } = scripted(
    ok(DIFF),
    { code: 1, stdout: "", stderr: STARTED },
    ok(),
    { code: 1, stdout: "", stderr: "Error: invalid comment type\n" },
  );
  const seeded = await seedTour(run, WHERE, SPEC);
  assert.equal(seeded.ok, false);
  assert.match(seeded.ok ? "" : seeded.error, /comment 1 of 3/);
  assert.match(seeded.ok ? "" : seeded.error, /invalid comment type/);
});
