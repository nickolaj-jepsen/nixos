/**
 * A1's grammar (D11): the four subcommands, a bare `/review`, pass-through argv,
 * the streaming refusal (D5) and the resume a live socket asks for.
 *
 * B2 is the case with spaces and quotes: the owner's typing reaches tuicr as
 * argv elements, so the assertion is a deep-equal on `args`, not on a string.
 * Nothing here starts tuicr or a review; the ctx is a stub that records what
 * dispatch asked for.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Theme, TUI } from "@earendil-works/pi-tui";
import { parseReview, splitArgv } from "./command.ts";
import { socketPath } from "./types.ts";

const gitIn = (cwd: string, args: string[]) =>
  execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();

/** A throwaway checkout with one commit and one uncommitted change. */
const repo = (t: TestContext) => {
  const dir = mkdtempSync(join(tmpdir(), "review-command-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  gitIn(dir, ["init", "-q", "-b", "main"]);
  gitIn(dir, ["config", "user.email", "review@example.invalid"]);
  gitIn(dir, ["config", "user.name", "Review"]);
  writeFileSync(join(dir, "a.ts"), "one\n");
  gitIn(dir, ["add", "."]);
  gitIn(dir, ["commit", "-qm", "fixture"]);
  writeFileSync(join(dir, "a.ts"), "two\n");
  return dir;
};

const theme = {
  fg: (_color: string, text: string) => text,
  bold: (text: string) => text,
  style: (text: string) => text,
} as unknown as Theme;

const tui = { terminal: { rows: 40, columns: 120 }, requestRender: () => {} } as unknown as TUI;

type CtxOptions = {
  idle?: boolean;
  keys?: readonly string[];
  /** Terminal UI: mode and hasUI together, as pi reports them. */
  terminal?: boolean;
  answer?: string;
};

/** A context that answers what dispatch asks, and remembers what it was asked for. */
const ctxFor = (cwd: string, options: CtxOptions = {}) => {
  const calls: { custom: number; input: number; notify: string[] } = {
    custom: 0,
    input: 0,
    notify: [],
  };
  const ctx = {
    cwd,
    mode: options.terminal === false ? "rpc" : "tui",
    hasUI: options.terminal !== false,
    isIdle: () => options.idle !== false,
    ui: {
      custom: async (
        factory: (tui: TUI, theme: Theme, keys: undefined, done: (value: unknown) => void) => {
          handleInput(data: string): void;
        },
      ) => {
        calls.custom += 1;
        let picked: unknown;
        const component = factory(tui, theme, undefined, (value) => {
          picked = value;
        });
        for (const key of options.keys ?? []) component.handleInput(key);
        return picked;
      },
      input: async () => {
        calls.input += 1;
        return options.answer;
      },
      notify: (message: string) => calls.notify.push(message),
    },
  } as unknown as ExtensionContext;
  return { ctx, calls };
};

/** A scratch runtime dir, so a socket test never looks at the owner's. */
const runtimeDir = (t: TestContext) => {
  const dir = mkdtempSync(join(tmpdir(), "review-command-run-"));
  const previous = process.env.XDG_RUNTIME_DIR;
  process.env.XDG_RUNTIME_DIR = dir;
  t.after(() => {
    if (previous === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = previous;
    rmSync(dir, { recursive: true, force: true });
  });
  return dir;
};

test("D11 the four subcommands are told apart, whatever the spacing", async () => {
  const cwd = tmpdir();
  for (const kind of ["inbox", "send", "take", "kill"] as const) {
    assert.deepEqual(await parseReview(kind, ctxFor(cwd).ctx), { kind });
    assert.deepEqual(await parseReview(`  ${kind}  `, ctxFor(cwd).ctx), { kind });
  }
});

test("D11 a bare /review asks which scope to review", async (t) => {
  runtimeDir(t);
  const dir = repo(t);
  const { ctx, calls } = ctxFor(dir, { keys: ["\r"] });
  const parsed = await parseReview("", ctx);
  assert.equal(calls.custom, 1, "the picker is the bare case");
  // The fixture's first row is the uncommitted change it has.
  assert.deepEqual(parsed, { kind: "open", scope: { mode: "worktree", args: ["-w"] } });
});

test("D11 a cancelled picker says none, so dispatch stays silent", async (t) => {
  runtimeDir(t);
  const dir = repo(t);
  assert.deepEqual(await parseReview("", ctxFor(dir, { keys: ["\x1b"] }).ctx), { kind: "none" });
});

test("D11 a live review resumes instead of asking, and no picker opens", async (t) => {
  const runtime = runtimeDir(t);
  const dir = repo(t);
  // C6's socket path for this checkout, created by hand: A2 owns making it.
  const socket = socketPath(runtime, dir);
  mkdirSync(dirname(socket), { recursive: true });
  writeFileSync(socket, "");
  assert.equal(existsSync(socket), true);
  const { ctx, calls } = ctxFor(dir, { keys: ["\r"] });
  assert.deepEqual(await parseReview("", ctx), { kind: "open", scope: undefined });
  assert.equal(calls.custom, 0);
});

test("D11 without a terminal the bare case opens tuicr's own view", async (t) => {
  runtimeDir(t);
  const dir = repo(t);
  const { ctx, calls } = ctxFor(dir, { terminal: false });
  assert.deepEqual(await parseReview("", ctx), { kind: "open", scope: undefined });
  assert.equal(calls.custom, 0);
  assert.deepEqual(calls.notify, ["review: no scope picker without the terminal UI"]);
});

test("D5 a streaming agent is refused, and nothing is picked or spawned", async (t) => {
  const runtime = runtimeDir(t);
  const dir = repo(t);
  for (const args of ["", "-r 'a..b'"]) {
    const { ctx, calls } = ctxFor(dir, { idle: false, keys: ["\r"] });
    assert.deepEqual(await parseReview(args, ctx), {
      kind: "refused",
      why: "review: the agent is still answering",
    });
    assert.equal(calls.custom, 0, "no picker while streaming");
    assert.equal(calls.input, 0);
    // A refused review leaves no socket behind, because it never started one.
    assert.equal(existsSync(join(runtime, "pi-review")), false);
  }
  // The subcommands never take the terminal, so a streaming turn does not block them.
  assert.deepEqual(await parseReview("inbox", ctxFor(dir, { idle: false }).ctx), { kind: "inbox" });
});

test("B2 pass-through is the typed argv, split without a shell", async () => {
  const cwd = tmpdir();
  assert.deepEqual(await parseReview("-r 'a..b'", ctxFor(cwd).ctx), {
    kind: "open",
    scope: { mode: "revset", args: ["-r", "a..b"] },
  });
  // Spaces and quotes stay inside one element, and nothing expands or globs.
  const revset = 'a..b --author "Jo Doe" --grep $HOME *';
  const parsed = await parseReview(`-r '${revset}'`, ctxFor(cwd).ctx);
  assert.deepEqual(parsed, { kind: "open", scope: { mode: "revset", args: ["-r", revset] } });
  // An argv the picker would have pinned is passed through unchanged instead.
  assert.deepEqual(await parseReview("-A", ctxFor(cwd).ctx), {
    kind: "open",
    scope: { mode: "all", args: ["-A"] },
  });
  assert.deepEqual(await parseReview("pr 42", ctxFor(cwd).ctx), {
    kind: "open",
    scope: { mode: "pr", args: ["pr", "42"], target: "42" },
  });
});

test("-p never enters args, and on its own there is no scope to pin", async () => {
  const cwd = tmpdir();
  assert.deepEqual(await parseReview("-w -p a.ts", ctxFor(cwd).ctx), {
    kind: "open",
    scope: { mode: "worktree", args: ["-w"] },
  });
  assert.deepEqual(await parseReview("--path=src -A", ctxFor(cwd).ctx), {
    kind: "open",
    scope: { mode: "all", args: ["-A"] },
  });
  assert.deepEqual(await parseReview("-p a.ts", ctxFor(cwd).ctx), {
    kind: "refused",
    why: "review: -p only filters the diff; name a scope too",
  });
});

test("typed text is split like a shell would, without being one", () => {
  assert.deepEqual(splitArgv(""), []);
  assert.deepEqual(splitArgv("  -w   -A "), ["-w", "-A"]);
  assert.deepEqual(splitArgv("-r 'a..b'"), ["-r", "a..b"]);
  assert.deepEqual(splitArgv(`-r "a..b --author 'Jo Doe'"`), ["-r", "a..b --author 'Jo Doe'"]);
  // A shell would expand these; here they are characters.
  assert.deepEqual(splitArgv("$HOME *.ts"), ["$HOME", "*.ts"]);
  assert.deepEqual(splitArgv("a\\ b"), ["a b"]);
  assert.deepEqual(splitArgv("''"), [""]);
  // Unclosed quotes run to the end rather than throwing mid-typing.
  assert.deepEqual(splitArgv("-r 'a..b"), ["-r", "a..b"]);
});
