/**
 * A5's two behaviours: C5's batch text handed to the prompt above whatever the
 * owner already had there, and D4's clear-on-submit, where a submitted prompt
 * carrying the batch's marker line is what makes the comments sent.
 *
 * B1 is asserted here rather than described: a comment whose body holds
 * backticks, a newline and a shell's worth of punctuation comes out as exactly
 * those bytes in the prompt, and nothing on this path builds a command.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionContext, InputEvent } from "@earendil-works/pi-coding-agent";
import { reviewInput, sendBatch } from "./batch.ts";
import type { ReviewEnv } from "./env.ts";
import { batchMarker } from "./types.ts";
import { REVIEW_ENTRY, type InboxItem, type ReviewEntry } from "./types.ts";

const SLUG = "repo@main/staged-and-unstaged/9d1b591";
const ROOT = "/work/repo";

type Branch = { type: string; customType?: string; data?: unknown }[];

/** One session: the branch, the editor, the notices it was given, and the appends pi saw. */
const session = (options: { entry?: ReviewEntry; draft?: string } = {}) => {
  const branch: Branch = [];
  if (options.entry !== undefined)
    branch.push({ type: "custom", customType: REVIEW_ENTRY, data: options.entry });
  let editor = options.draft ?? "";
  const notices: { text: string; level: string }[] = [];
  const ctx = {
    mode: "tui",
    hasUI: true,
    cwd: ROOT,
    sessionManager: {
      getSessionId: () => "session-1",
      getBranch: () => branch,
    },
    ui: {
      getEditorText: () => editor,
      setEditorText: (text: string) => {
        editor = text;
      },
      notify: (text: string, level: string) => {
        notices.push({ text, level });
      },
    },
  } as unknown as ExtensionContext;
  const env = {
    pi: {
      appendEntry: (customType: string, data: unknown) => {
        branch.push({ type: "custom", customType, data });
      },
    },
  } as unknown as ReviewEnv;
  return {
    branch,
    env,
    ctx,
    notices,
    editor: () => editor,
    recorded: () =>
      branch
        .map((record) => record.data as ReviewEntry | undefined)
        .filter((data): data is ReviewEntry => data !== undefined)
        .at(-1),
  };
};

const item = (over: Partial<InboxItem> = {}): InboxItem => ({
  id: "a",
  path: "src/a.ts",
  startLine: 42,
  endLine: 42,
  side: "new",
  type: "issue",
  author: "Nickolaj",
  body: "guard the empty token",
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

const entry = (over: Partial<ReviewEntry> = {}): ReviewEntry => ({
  v: 1,
  root: ROOT,
  cwd: ROOT,
  harness: "pi",
  slug: SLUG,
  scope: { mode: "worktree", args: ["-w"] },
  socket: "/run/user/1000/pi-review/0123456789abcdef.sock",
  items: [],
  seen: [],
  sent: [],
  progress: { reviewedCount: 1, fileCount: 2 },
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

const submitted = (text: string): InputEvent =>
  ({ type: "input", text, source: "interactive" }) as InputEvent;

test("C5 the batch is the header and three numbered comments, byte for byte", async () => {
  const items = [
    // A review-level comment: no path and no line, so no location segment.
    item({
      id: "1",
      path: null,
      startLine: null,
      endLine: null,
      type: "note",
      body: "check the migration",
    }),
    // A range keeps both ends.
    item({
      id: "2",
      path: "path/to/file.ts",
      startLine: 88,
      endLine: 92,
      type: "nit",
      body: "rename this",
    }),
    // B1: backticks, a newline, and shell punctuation are data, not a command.
    item({
      id: "3",
      path: "a.ts",
      startLine: 7,
      endLine: 7,
      type: null,
      body: 'don\'t run `rm -rf $(pwd)` here;\nsee `tuicr review add --content "x"` as an example',
    }),
  ];
  const { env, ctx, editor, notices } = session({ entry: entry({ items }) });
  await sendBatch(env, ctx);
  assert.equal(
    editor(),
    [
      `Review comments from tuicr (session ${SLUG}, repo ${ROOT}). Read the full JSON with`,
      `${batchMarker(SLUG)} (tuicr skill) if you need it.`,
      "",
      "1. [note] check the migration",
      "2. `path/to/file.ts:88-92` [nit] rename this",
      "3. `a.ts:7` don't run `rm -rf $(pwd)` here;",
      'see `tuicr review add --content "x"` as an example',
    ].join("\n"),
  );
  assert.deepEqual(notices, [{ text: "review: 3 comments prefilled", level: "info" }]);
});

test("D4 the batch goes above the draft, which is untouched below it", async () => {
  const draft = "please also update the docs\nand the changelog";
  const { env, ctx, editor } = session({ entry: entry({ items: [item()] }), draft });
  await sendBatch(env, ctx);
  const text = editor();
  assert.ok(text.endsWith(`\n\n${draft}`), "one blank line between the batch and the draft");
  const batch = text.slice(0, text.length - draft.length - 2);
  assert.match(batch, /^Review comments from tuicr \(session /);
  assert.ok(batch.endsWith("1. `src/a.ts:42` [issue] guard the empty token\n".trimEnd()));
  // The draft is still one text: nothing escaped it, wrapped it or numbered it.
  assert.equal(text.split(draft).length, 2);
});

test("D4 an inbox that is empty sends nothing and leaves the editor alone", async () => {
  const { env, ctx, editor, notices, branch } = session({
    entry: entry({ items: [item({ id: "a" })], sent: ["a"] }),
    draft: "a draft",
  });
  await sendBatch(env, ctx);
  assert.equal(editor(), "a draft");
  assert.deepEqual(notices, [{ text: "review: no comments to send", level: "info" }]);
  assert.equal(branch.length, 1);
  // No review at all reads the same way: nothing to hand over.
  const empty = session();
  await sendBatch(empty.env, empty.ctx);
  assert.deepEqual(empty.notices, [{ text: "review: no comments to send", level: "info" }]);
});

test("D4 a submit carrying the marker sends exactly the comments the batch carried", async () => {
  const { env, ctx, branch, recorded } = session({
    entry: entry({ items: [item({ id: "a" }), item({ id: "b", body: "rename this" })] }),
  });
  await sendBatch(env, ctx);
  // Ingest recorded a comment while the batch sat in the prompt: the batch does
  // not hold it, so the submit must not mark it delivered.
  branch.push({
    type: "custom",
    customType: REVIEW_ENTRY,
    data: entry({
      items: [
        item({ id: "a" }),
        item({ id: "b", body: "rename this" }),
        item({ id: "c", body: "arrived later" }),
      ],
    }),
  });
  await reviewInput(env, submitted(`${batchMarker(SLUG)}\n\nmy own note`), ctx);
  assert.deepEqual(recorded()?.sent, ["a", "b"]);

  // A prompt without the marker delivered nothing.
  const quiet = session({ entry: entry({ items: [item()] }) });
  await reviewInput(quiet.env, submitted("just a question"), quiet.ctx);
  assert.equal(quiet.recorded()?.items.length, 1);
  assert.deepEqual(quiet.recorded()?.sent ?? [], []);
});

test("D4 the marker of another session's batch does not empty this inbox", async () => {
  const { env, ctx, recorded } = session({ entry: entry({ items: [item()] }) });
  await sendBatch(env, ctx);
  await reviewInput(env, submitted(batchMarker("other@main/unstaged/fffffff")), ctx);
  assert.deepEqual(recorded()?.sent ?? [], []);
});

test("D4 a second submit of the same batch appends nothing", async () => {
  const { env, ctx, branch, recorded } = session({ entry: entry({ items: [item()] }) });
  await sendBatch(env, ctx);
  const text = batchMarker(SLUG);
  await reviewInput(env, submitted(text), ctx);
  const after = branch.length;
  await reviewInput(env, submitted(text), ctx);
  assert.deepEqual(recorded()?.sent, ["a"]);
  // The second submit found nothing new: no entry was recorded.
  assert.equal(branch.length, after);
  // And the inbox stays empty for the next send.
  await sendBatch(env, ctx);
  assert.equal(recorded()?.sent.length, 1);
});
