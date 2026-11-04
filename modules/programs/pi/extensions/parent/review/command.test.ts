/**
 * `/rv`'s grammar (D11): the two subcommands, the scope shortcuts, and tuicr's
 * own argv passed through. A review lives only as long as tuicr does, so a bare
 * `/rv` is tuicr's default view and nothing is asked first.
 *
 * B2 is the case with spaces and quotes: the owner's typing reaches tuicr as
 * argv elements, so the assertion is a deep-equal on `args`, not on a string.
 * Nothing here starts tuicr; the ctx is a stub that records what dispatch asked
 * for.
 */
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { parseReview, splitArgv } from "./command.ts";

type CtxOptions = { idle?: boolean; terminal?: boolean };

/** A context that remembers what dispatch asked it for. */
const ctxFor = (cwd: string, options: CtxOptions = {}) => {
  const calls = { custom: 0, input: 0, notify: [] as string[] };
  const ctx = {
    cwd,
    mode: options.terminal === false ? "rpc" : "tui",
    hasUI: options.terminal !== false,
    isIdle: () => options.idle !== false,
    ui: {
      custom: async () => {
        calls.custom += 1;
        return undefined;
      },
      input: async () => {
        calls.input += 1;
        return undefined;
      },
      notify: (message: string) => calls.notify.push(message),
    },
  } as unknown as ExtensionContext;
  return { ctx, calls };
};

test("D11 the two subcommands are told apart, whatever the spacing", async () => {
  const cwd = tmpdir();
  for (const kind of ["inbox", "send"] as const) {
    assert.deepEqual(await parseReview(kind, ctxFor(cwd).ctx), { kind });
    assert.deepEqual(await parseReview(`  ${kind}  `, ctxFor(cwd).ctx), { kind });
  }
});

test("D11 a bare /rv is tuicr's own view, and nothing is asked first", async (t) => {
  const dir = tmpdir();
  const { ctx, calls } = ctxFor(dir);
  assert.deepEqual(await parseReview("", ctx), { kind: "open", args: [] });
  assert.equal(calls.custom, 0, "no picker to open");
});

test("D11 a scope word is the tuicr argv it stands for", async (t) => {
  const dir = tmpdir();
  const { ctx } = ctxFor(dir);
  assert.deepEqual(await parseReview("changes", ctx), { kind: "open", args: ["-w"] });
  assert.deepEqual(await parseReview("all", ctx), { kind: "open", args: ["-A"] });
  assert.deepEqual(await parseReview("last", ctx), {
    kind: "open",
    args: ["-r", "HEAD~1..HEAD"],
  });
  assert.deepEqual(await parseReview("branch", ctx), {
    kind: "open",
    args: ["-r", "origin/HEAD..HEAD", "-w"],
  });
});

test("D5 a streaming agent is refused, and nothing is spawned", async (t) => {
  const dir = tmpdir();
  for (const args of ["", "-r 'a..b'", "changes"]) {
    const { ctx, calls } = ctxFor(dir, { idle: false });
    assert.deepEqual(await parseReview(args, ctx), {
      kind: "refused",
      why: "review: the agent is still answering",
    });
    assert.equal(calls.custom, 0);
    assert.equal(calls.input, 0);
  }
  // The subcommands never take the terminal, so a streaming turn does not block them.
  assert.deepEqual(await parseReview("inbox", ctxFor(dir, { idle: false }).ctx), { kind: "inbox" });
});

test("B2 pass-through is the typed argv, split without a shell", async () => {
  const cwd = tmpdir();
  assert.deepEqual(await parseReview("-r 'a..b'", ctxFor(cwd).ctx), {
    kind: "open",
    args: ["-r", "a..b"],
  });
  // Spaces and quotes stay inside one element, and nothing expands or globs.
  const revset = 'a..b --author "Jo Doe" --grep $HOME *';
  const parsed = await parseReview(`-r '${revset}'`, ctxFor(cwd).ctx);
  assert.deepEqual(parsed, { kind: "open", args: ["-r", revset] });
  assert.deepEqual(await parseReview("-A", ctxFor(cwd).ctx), { kind: "open", args: ["-A"] });
  assert.deepEqual(await parseReview("pr 42", ctxFor(cwd).ctx), {
    kind: "open",
    args: ["pr", "42"],
  });
  // A shortcut expands in place, so what follows it is still tuicr's argv.
  assert.deepEqual(await parseReview("changes -p a.ts", ctxFor(cwd).ctx), {
    kind: "open",
    args: ["-w", "-p", "a.ts"],
  });
  // Anything else is passed through as typed.
  assert.deepEqual(await parseReview("review", ctxFor(cwd).ctx), {
    kind: "open",
    args: ["review"],
  });
  assert.deepEqual(await parseReview("-p a.ts", ctxFor(cwd).ctx), {
    kind: "open",
    args: ["-p", "a.ts"],
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
