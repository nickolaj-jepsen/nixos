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
  CLAIM_FIELDS,
  REVIEW_ENTRY,
  REVIEW_ENTRY_FIELDS,
  batchMarker,
  batchText,
  claimPath,
  inboxItem,
  reviewKey,
  socketPath,
  tuicrArgv,
} from "./types.ts";
import { createReview } from "../review.ts";
import { parseReview } from "./command.ts";

const scope = { mode: "worktree" as const, args: ["-w"] };

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
    scope,
    socket: "/run/user/1000/pi-review/0123456789abcdef.sock",
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

test("C2 the claim sits under the agent dir, keyed by the repository", () => {
  const claim: Claim = {
    v: 1,
    root: "/work/repo",
    session: "session-1",
    harness: "claude",
    pid: 4242,
    slug: null,
    scope,
    seen: [],
    at: "2026-11-03T21:12:12.088148037+00:00",
  };
  assert.deepEqual(Object.keys(claim).sort(), Object.keys(CLAIM_FIELDS).sort());
  const path = claimPath("/agent", "/work/repo");
  assert.equal(path, `/agent/review-claims/${reviewKey("/work/repo")}.json`);
  assert.match(path, /\/[0-9a-f]{16}\.json$/);
  assert.notEqual(claimPath("/agent", "/work/repo"), claimPath("/agent", "/other/repo"));
});

test("C3 a pinned scope names a mode and the argv tuicr gets", () => {
  assert.deepEqual(tuicrArgv({ mode: "worktree", args: [] }), ["-w"]);
  assert.deepEqual(tuicrArgv({ mode: "all", args: [] }), ["-A"]);
  assert.deepEqual(tuicrArgv({ mode: "picker", args: [] }), []);
  assert.deepEqual(tuicrArgv({ mode: "pr", args: [], target: "42" }), ["pr", "42"]);
  assert.deepEqual(tuicrArgv({ mode: "commits", args: [], base: "8cae48e", head: "9d1b591" }), [
    "-r",
    "8cae48e..9d1b591",
    "-w",
  ]);
  assert.deepEqual(
    tuicrArgv({ mode: "commits", args: ["-r", "9d1b591~1..9d1b591"], head: "9d1b591" }),
    ["-r", "9d1b591~1..9d1b591"],
  );
  // Last commit, unresolved: the parent is spelled out so the slug is commits/, not unstaged/.
  assert.deepEqual(tuicrArgv({ mode: "commits", args: [], head: "9d1b591" }), [
    "-r",
    "9d1b591~1..9d1b591",
  ]);
  assert.deepEqual(tuicrArgv({ mode: "commits", args: [] }), []);
  const revset = ["-r", 'a..b --author "Jo Doe"'];
  assert.deepEqual(tuicrArgv({ mode: "revset", args: revset }), revset);
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
  assert.match(batchText(slug, root, items), new RegExp(`session ${slug}`));
});

test("C6 the socket and the module surface", () => {
  const path = socketPath("/run/user/1000", "/work/repo");
  assert.equal(path, `/run/user/1000/pi-review/${reviewKey("/work/repo")}.sock`);
  assert.match(path, /\/[0-9a-f]{16}\.sock$/);
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

test("D11 the subcommands are told apart", async () => {
  // A real, hermetic cwd: the bare case asks git where it is, even when nothing is picked.
  const ctx = { isIdle: () => true, cwd: tmpdir(), ui: { notify: () => {} } } as never;
  assert.deepEqual(await parseReview("", ctx), { kind: "open", scope: undefined });
  for (const kind of ["inbox", "send", "take", "kill"] as const) {
    assert.deepEqual(await parseReview(kind, ctx), { kind });
    assert.deepEqual(await parseReview(`  ${kind}  `, ctx), { kind });
  }
});
