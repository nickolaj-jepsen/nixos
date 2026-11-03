/**
 * A1's pinning: D1's rows as the picker shows them, the argv each one pins (D2),
 * and the per-row availability the acceptance names — a clean tree, a detached
 * HEAD and a checkout with no `origin/HEAD`.
 *
 * The table and the pinning are pure, so most cases feed fixtures. The facts
 * that need a repository are read from throwaway ones in the test's own tmp
 * directory; nothing here touches the owner's review store.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import type { TUI } from "@earendil-works/pi-tui";
import {
  ScopePicker,
  type ScopeChoice,
  type ScopeFacts,
  chooseScope,
  pinArgv,
  pinScope,
  readFacts,
  rows,
} from "./scope.ts";
import { tuicrArgv } from "./types.ts";

const SHA_A = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
const SHA_B = "b1b2c3d4e5f60718293a4b5c6d7e8f9012345678";

const facts = (over: Partial<ScopeFacts> = {}): ScopeFacts => ({
  cwd: "/work/repo",
  root: "/work/repo",
  head: SHA_A,
  base: SHA_B,
  dirty: true,
  parent: true,
  gh: true,
  ...over,
});

const gitIn = (cwd: string, args: string[]) =>
  execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();

/** A throwaway checkout: one commit `fixture`, optionally a second, optionally dirty. */
const repo = (t: TestContext, options: { dirty?: boolean; origin?: boolean } = {}) => {
  const dir = mkdtempSync(join(tmpdir(), "review-scope-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  gitIn(dir, ["init", "-q", "-b", "main"]);
  gitIn(dir, ["config", "user.email", "review@example.invalid"]);
  gitIn(dir, ["config", "user.name", "Review"]);
  writeFileSync(join(dir, "a.ts"), "one\n");
  writeFileSync(join(dir, "b.ts"), "two\n");
  gitIn(dir, ["add", "."]);
  gitIn(dir, ["commit", "-qm", "fixture"]);
  if (options.origin === true) {
    const remote = `${dir}-origin.git`;
    t.after(() => rmSync(remote, { recursive: true, force: true }));
    gitIn(tmpdir(), ["init", "-q", "--bare", remote]);
    gitIn(dir, ["remote", "add", "origin", remote]);
    gitIn(dir, ["push", "-q", "origin", "main"]);
    // The pointer a clone would leave behind; a local path needs no network.
    gitIn(dir, ["remote", "set-head", "origin", "--auto"]);
  }
  if (options.dirty !== false) appendFileSync(join(dir, "a.ts"), "three\n");
  return dir;
};

// --- the table and the pinning, from facts -------------------------------

test("D1 the rows are D1's, in order, and an unavailable one says why", () => {
  const table = rows(facts({ base: null, parent: false, gh: false }));
  assert.deepEqual(
    table.map((row) => row.id),
    ["worktree", "branch", "lastCommit", "picker", "all", "pr", "revset"],
  );
  assert.deepEqual(
    table.filter((row) => row.unavailable !== undefined).map((row) => row.unavailable),
    ["no origin/HEAD", "no parent commit", "gh is not installed"],
  );
  // The two that ask for text say so, and only they do.
  assert.deepEqual(
    table.filter((row) => row.asks !== undefined).map((row) => row.id),
    ["pr", "revset"],
  );
});

test("D1 a clean tree offers no uncommitted review, and says so", () => {
  const table = rows(facts({ dirty: false }));
  assert.equal(table[0]?.unavailable, "the working tree is clean");
  assert.deepEqual(pinScope({ row: "worktree" }, facts({ dirty: false })), {
    ok: false,
    why: "review: the working tree is clean",
  });
  assert.deepEqual(pinScope({ row: "worktree" }, facts()), {
    ok: true,
    scope: { mode: "worktree", args: ["-w"] },
  });
});

test("D2 the branch row pins both ends to hashes, never a branch name", () => {
  const picked = pinScope({ row: "branch" }, facts({ dirty: true }));
  assert.deepEqual(picked, {
    ok: true,
    scope: {
      mode: "commits",
      args: ["-r", `${SHA_B}..${SHA_A}`, "-w"],
      base: SHA_B,
      head: SHA_A,
    },
  });
});

test("D2 the last commit spells out its parent, so its identity stays commits/", () => {
  const picked = pinScope({ row: "lastCommit" }, facts());
  assert.deepEqual(picked, {
    ok: true,
    scope: { mode: "commits", args: ["-r", `${SHA_A}~1..${SHA_A}`], head: SHA_A },
  });
  // A root commit has no range to review under that identity.
  assert.deepEqual(pinScope({ row: "lastCommit" }, facts({ parent: false })), {
    ok: false,
    why: "review: no parent commit",
  });
});

test("D1 the two rows that review without a range pin the flags they name", () => {
  assert.deepEqual(pinScope({ row: "picker" }, facts()), {
    ok: true,
    scope: { mode: "picker", args: [] },
  });
  assert.deepEqual(pinScope({ row: "all" }, facts()), {
    ok: true,
    scope: { mode: "all", args: ["-A"] },
  });
});

test("C6 every pinned scope's args are the argv tuicr is launched with", () => {
  const choices: ScopeChoice[] = [
    { row: "worktree" },
    { row: "branch" },
    { row: "lastCommit" },
    { row: "picker" },
    { row: "all" },
    { row: "pr", text: "42" },
    { row: "revset", text: "main..HEAD" },
  ];
  for (const choice of choices) {
    const picked = pinScope(choice, facts());
    assert.equal(picked.ok, true, choice.row);
    if (!picked.ok) continue;
    assert.deepEqual(tuicrArgv(picked.scope), picked.scope.args, choice.row);
  }
});

test("D1 a PR target and a revset are typed, and each pins as one element", () => {
  assert.deepEqual(pinScope({ row: "pr", text: " owner/repo#42 " }, facts()), {
    ok: true,
    scope: { mode: "pr", args: ["pr", "owner/repo#42"], target: "owner/repo#42" },
  });
  assert.deepEqual(pinScope({ row: "pr", text: "  " }, facts()), {
    ok: false,
    why: "review: no pull request named",
  });
  // An owner who typed the flag already still gets one `-r`.
  assert.deepEqual(pinScope({ row: "revset", text: "-r main..HEAD" }, facts()), {
    ok: true,
    scope: { mode: "revset", args: ["-r", "main..HEAD"] },
  });
});

test("B2 pass-through argv is kept as typed, and -p never enters args", () => {
  assert.deepEqual(pinArgv(["-r", "a..b"]), { mode: "revset", args: ["-r", "a..b"] });
  assert.deepEqual(pinArgv(["-w", "-p", "a.ts"]), { mode: "worktree", args: ["-w"] });
  assert.deepEqual(pinArgv(["-w", "--path=a.ts"]), { mode: "worktree", args: ["-w"] });
  assert.deepEqual(pinArgv(["-pa.ts", "-A"]), { mode: "all", args: ["-A"] });
  assert.equal(pinArgv(["-p", "a.ts"]), undefined);
  assert.deepEqual(pinArgv(["pr", "42"]), { mode: "pr", args: ["pr", "42"], target: "42" });
  // Anything else keeps every element in place: the argv is the scope.
  const argv = ["-w", "-r", 'main..HEAD --author "Jo Doe"'];
  assert.deepEqual(pinArgv(argv), { mode: "revset", args: argv });
});

// --- the table and the pinning, from a repository ------------------------

test("a dirty checkout reports the changes -w would show, and a clean one does not", async (t) => {
  const dirty = repo(t);
  const before = await readFacts(dirty);
  assert.equal(before.root, dirty);
  assert.equal(before.dirty, true);
  assert.equal(before.parent, false);
  assert.equal(before.base, null);
  assert.match(before.head ?? "", /^[0-9a-f]{40}$/);
  assert.equal(rows(before)[0]?.unavailable, undefined);

  gitIn(dirty, ["commit", "-qam", "the change"]);
  const after = await readFacts(dirty);
  assert.equal(after.dirty, false);
  assert.equal(after.parent, true);
  assert.equal(rows(after)[0]?.unavailable, "the working tree is clean");
});

test("origin/HEAD is what the branch row pins, and its absence is a reason", async (t) => {
  const plain = repo(t);
  assert.equal(rows(await readFacts(plain))[1]?.unavailable, "no origin/HEAD");

  const withOrigin = repo(t, { origin: true });
  const factsOf = await readFacts(withOrigin);
  assert.match(factsOf.base ?? "", /^[0-9a-f]{40}$/);
  assert.equal(rows(factsOf)[1]?.unavailable, undefined);
  const picked = pinScope({ row: "branch" }, factsOf);
  assert.equal(picked.ok, true);
  assert.deepEqual(picked.ok ? picked.scope.args : [], [
    "-r",
    `${factsOf.base}..${factsOf.head}`,
    "-w",
  ]);
});

test("a detached HEAD pins the same hashes as the branch would", async (t) => {
  const dir = repo(t, { origin: true });
  gitIn(dir, ["commit", "-qam", "second"]);
  const onBranch = await readFacts(dir);
  gitIn(dir, ["checkout", "-q", "--detach", "HEAD"]);
  const detached = await readFacts(dir);
  assert.equal(detached.head, onBranch.head);
  assert.equal(detached.base, onBranch.base);
  // No branch name to fall back on, which is why the range is resolved at all.
  const picked = pinScope({ row: "branch" }, detached);
  assert.deepEqual(picked.ok ? picked.scope.args : [], [
    "-r",
    `${onBranch.base}..${onBranch.head}`,
    "-w",
  ]);
});

test("outside git there are no facts to pin, and no rows", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "review-scope-plain-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const outside = await readFacts(dir);
  assert.equal(outside.root, null);
  assert.equal(outside.head, null);
  assert.equal(rows(outside)[0]?.unavailable, "the working tree is clean");
});

// --- the picker ----------------------------------------------------------

const theme = {
  fg: (_color: string, text: string) => text,
  bold: (text: string) => text,
  style: (text: string) => text,
} as unknown as Theme;

const tui = { terminal: { rows: 40, columns: 120 }, requestRender: () => {} } as unknown as TUI;

/** The rows as the pane would show them, one string per line. */
const drawn = (factsFor: ScopeFacts) =>
  new ScopePicker(tui, theme, factsFor, () => {}).render(64).join("\n");

test("the picker draws every row, and the reason an unavailable one cannot be picked", () => {
  const pane = drawn(facts({ base: null, parent: false, gh: false, dirty: false }));
  for (const label of [
    "uncommitted changes",
    "branch vs origin/HEAD",
    "last commit",
    "tuicr's commit picker",
    "every tracked file",
    "pull request",
    "custom revset",
  ])
    assert.match(pane, new RegExp(label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  for (const reason of [
    "the working tree is clean",
    "no origin/HEAD",
    "no parent commit",
    "gh is not installed",
  ])
    assert.match(pane, new RegExp(reason));
  // The cursor starts on the first row that can be picked.
  assert.match(pane, /› uncommitted changes|› tuicr's commit picker/);
  assert.match(pane, /esc cancel/);
});

test("the cursor skips the rows that cannot be picked", () => {
  const picker = new ScopePicker(
    tui,
    theme,
    facts({ dirty: true, base: null, parent: false, gh: false }),
    () => {},
  );
  const selected = () => picker.render(64).find((line) => line.includes("›")) ?? "";
  assert.match(selected(), /uncommitted changes/);
  picker.handleInput("j");
  // branch and last commit are unavailable in this checkout, so it lands on the picker row.
  assert.match(selected(), /tuicr's commit picker/);
  picker.handleInput("j");
  assert.match(selected(), /every tracked file/);
  picker.handleInput("k");
  assert.match(selected(), /tuicr's commit picker/);
});

/**
 * What the picker hands back, without a terminal: the real component driven by
 * keys, or the row a test names when the row's position depends on the machine
 * (a `gh` on PATH shifts them).
 */
const choose = async (
  cwd: string,
  options: { keys?: readonly string[]; choice?: ScopeChoice; answer?: string },
): Promise<{ scope: unknown; picked: unknown; notices: string[] }> => {
  let picked: unknown;
  const notices: string[] = [];
  const ctx = {
    cwd,
    mode: "tui",
    hasUI: true,
    isIdle: () => true,
    ui: {
      custom: async (
        factory: (
          tui: TUI,
          theme: Theme,
          keys: undefined,
          done: (value: unknown) => void,
        ) => {
          handleInput(data: string): void;
        },
      ) => {
        const component = factory(tui, theme, undefined, (value) => {
          picked = value;
        });
        if (options.choice !== undefined) picked = options.choice;
        else for (const key of options.keys ?? []) component.handleInput(key);
        return picked;
      },
      input: async () => options.answer,
      notify: (message: string) => notices.push(message),
    },
  } as unknown as ExtensionContext;
  const scope = await chooseScope(ctx);
  return { scope, picked, notices };
};

test("the picker hands back the pinned scope of the row enter lands on", async (t) => {
  const dir = repo(t);
  const { scope } = await choose(dir, { keys: ["j", "j", "\r"] });
  assert.deepEqual(scope, { mode: "all", args: ["-A"] });
});

test("escape cancels, and a text row cancelled at the prompt pins nothing", async (t) => {
  const dir = repo(t);
  assert.equal((await choose(dir, { keys: ["\x1b"] })).scope, undefined);
  const cancelled = await choose(dir, { choice: { row: "revset" } });
  assert.deepEqual(cancelled.picked, { row: "revset" });
  assert.equal(cancelled.scope, undefined);
});

test("a typed revset leaves as one argv element, quotes and spaces intact", async (t) => {
  const dir = repo(t);
  const text = 'main..HEAD --author "Jo Doe"';
  const { scope } = await choose(dir, { choice: { row: "revset" }, answer: text });
  assert.deepEqual(scope, { mode: "revset", args: ["-r", text] });
});

test("a typed PR target pins as one element, and an empty one refuses", async (t) => {
  const dir = repo(t);
  assert.deepEqual((await choose(dir, { choice: { row: "pr" }, answer: "owner/repo#42" })).scope, {
    mode: "pr",
    args: ["pr", "owner/repo#42"],
    target: "owner/repo#42",
  });
  assert.deepEqual((await choose(dir, { choice: { row: "pr" }, answer: "  " })).scope, undefined);
});

test("outside git the picker refuses and says why", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "review-scope-nogit-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const { scope, notices } = await choose(dir, { keys: ["\r"] });
  assert.equal(scope, undefined);
  assert.deepEqual(notices, ["review: this folder is not a git checkout"]);
});
