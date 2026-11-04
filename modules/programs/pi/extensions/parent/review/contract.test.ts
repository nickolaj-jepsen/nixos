/**
 * The frozen contracts (HANDOFF C1–C6): one case per contract, asserting the
 * bytes and file names the Python side and the two harnesses agree on.
 */
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { test } from "node:test";
import {
  type Claim,
  type InboxItem,
  type ReviewEntry,
  REVIEW_ENTRY,
  REVIEW_ENTRY_FIELDS,
  batchMarker,
  batchText,
  inboxItem,
} from "./types.ts";
import { createReview } from "../review.ts";
import { parseReview } from "./command.ts";

const item = (over: Partial<InboxItem> = {}): InboxItem => ({
  id: "c1",
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

test("C1 the review entry carries exactly the recorded fields", () => {
  const entry: ReviewEntry = {
    v: 1,
    root: "/work/repo",
    cwd: "/work/repo",
    harness: "pi",
    slug: "repo@main/staged-and-unstaged/9d1b591",
    args: ["-w"],
    items: [item()],
    seen: ["c1"],
    sent: [],
    progress: { reviewedCount: 1, fileCount: 2 },
    at: "2026-11-03T21:12:12.088148037+00:00",
  };
  assert.equal(REVIEW_ENTRY, "review");
  assert.deepEqual(Object.keys(entry).sort(), Object.keys(REVIEW_ENTRY_FIELDS).sort());
  assert.deepEqual(Object.keys(entry.progress).sort(), ["fileCount", "reviewedCount"]);
});

test("C4 a comment maps to the inbox shape, whatever tuicr leaves out", () => {
  assert.deepEqual(
    inboxItem({
      id: "015bfe55",
      path: "a.txt",
      start_line: 5,
      end_line: 5,
      side: "new",
      comment_type: "issue",
      author: "Nickolaj",
      content: "outside comment",
      lifecycle_state: "local_draft",
      created_at: "2026-11-03T21:12:12.088148037+00:00",
    }),
    {
      id: "015bfe55",
      path: "a.txt",
      startLine: 5,
      endLine: 5,
      side: "new",
      type: "issue",
      author: "Nickolaj",
      body: "outside comment",
      at: "2026-11-03T21:12:12.088148037+00:00",
    },
  );
  assert.deepEqual(inboxItem({ id: "c2", content: "no path" }), {
    id: "c2",
    path: null,
    startLine: null,
    endLine: null,
    side: null,
    type: null,
    author: null,
    body: "no path",
    at: "",
  });
  // No id: a derived one, so the same comment keeps its id when the array reorders.
  const first = inboxItem({ path: "a.txt", start_line: 1, content: "same" });
  const reordered = inboxItem({ path: "a.txt", start_line: 1, content: "same" });
  assert.match(first.id, /^c-[0-9a-f]{16}$/);
  assert.equal(first.id, reordered.id);
  assert.notEqual(first.id, inboxItem({ path: "a.txt", start_line: 2, content: "same" }).id);
  // A number that is not a line is not a line.
  assert.equal(inboxItem({ start_line: "5" }).startLine, null);
});

test("C5 the batch is the header and a numbered list, byte for byte", () => {
  const slug = "repo@main/staged-and-unstaged/9d1b591";
  const root = "/work/repo";
  const items = [
    item({ id: "a", path: "path/to/file.ts", startLine: 42, endLine: 42, type: "issue" }),
    item({
      id: "b",
      path: "path/to/file.ts",
      startLine: 88,
      endLine: 92,
      type: "nit",
      body: "rename this",
    }),
  ];
  assert.equal(
    batchText(slug, root, items),
    [
      `Review comments from tuicr (session ${slug}, repo ${root}). Read the full JSON with`,
      `${batchMarker(slug)} (tuicr skill) if you need it.`,
      "",
      "1. `path/to/file.ts:42` [issue] guard the empty token",
      "2. `path/to/file.ts:88-92` [nit] rename this",
    ].join("\n"),
  );
  assert.equal(batchMarker(slug), `\`tuicr review comments --session ${slug}\``);
  // The editor draws the batch, and the model reads it: terminal control goes,
  // the rest of the bytes stay (B1).
  const hostile = batchText(slug, root, [
    item({ id: "h", body: "clear\x1b[2Jthe\x07screen", path: "a\x1b]52;c;x\x07.ts" }),
  ]);
  assert.ok(!hostile.includes("\x1b"), "an escape sequence survived into the batch");
  assert.match(hostile, /clearthescreen/);
  assert.match(hostile, /`a\.ts:42`/);
  assert.match(batchText(slug, root, items), new RegExp(`session ${slug}`));
});

test("C6 the module surface", () => {
  // The handle the chrome calls: one absent method and `measurements()` throws on every border.
  const review = createReview(
    { on: () => () => {}, registerCommand: () => {} } as never,
    { ctx: undefined, live: false, tui: undefined, editor: undefined, borderDrawn: false } as never,
    { dialogs: undefined, hub: undefined } as never,
  );
  for (const method of ["meter", "dispatch", "ingest", "shutdown", "waitLabel"] as const) {
    assert.equal(typeof review[method], "function", method);
  }
});

test("a refused review is what the owner is told, and nothing is opened", async () => {
  const review = createReview(
    { on: () => () => {}, registerCommand: () => {} } as never,
    { ctx: undefined, live: false, tui: undefined, editor: undefined, borderDrawn: false } as never,
    { dialogs: undefined, hub: undefined } as never,
  );
  const told: string[] = [];
  const ctx = {
    cwd: tmpdir(),
    mode: "tui",
    hasUI: true,
    isIdle: () => false,
    ui: { notify: (text: string) => told.push(text) },
  } as never;
  await review.dispatch("", ctx);
  assert.deepEqual(told, ["review: the agent is still answering"]);
});

test("D11 the subcommands are told apart", async () => {
  const ctx = { isIdle: () => true, cwd: tmpdir(), ui: { notify: () => {} } } as never;
  assert.deepEqual(await parseReview("", ctx), { kind: "open", args: [] });
  for (const kind of ["inbox", "send"] as const) {
    assert.deepEqual(await parseReview(kind, ctx), { kind });
    assert.deepEqual(await parseReview(`  ${kind}  `, ctx), { kind });
  }
});
