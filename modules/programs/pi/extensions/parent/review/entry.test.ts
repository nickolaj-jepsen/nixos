/**
 * C1's round trip: an entry appended to the session is the entry the next
 * session_start reads back, and nothing the branch holds that is not a review
 * entry is believed. A3's ingest reads and records through these two, so the
 * branch is the only state either of them may trust.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";
import { readEntry, recordEntry, restoreReview, sessionReview } from "./entry.ts";
import { REVIEW_ENTRY, type ReviewEntry } from "./types.ts";

/** The branch as pi hands it over: a list of session entries, oldest first. */
type Branch = { type: string; customType?: string; data?: unknown }[];

const ctx = (branch: Branch) =>
  ({ sessionManager: { getBranch: () => branch } }) as unknown as ExtensionContext;

const env = (branch: Branch) =>
  ({
    pi: {
      appendEntry: (customType: string, data: unknown) => {
        branch.push({ type: "custom", customType, data });
      },
    },
  }) as unknown as ReviewEnv;

const entry = (over: Partial<ReviewEntry> = {}): ReviewEntry => ({
  v: 1,
  root: "/work/repo",
  cwd: "/work/repo",
  harness: "pi",
  slug: "repo@main/staged-and-unstaged/9d1b591",
  args: ["-w"],
  items: [],
  seen: [],
  sent: [],
  progress: { reviewedCount: 1, fileCount: 2 },
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

test("C1 an entry recorded on the branch is the entry read back", async () => {
  const branch: Branch = [];
  const first = entry({ items: [], sent: [] });
  recordEntry(env(branch), ctx(branch), first);
  assert.equal(branch.length, 1);
  assert.deepEqual(branch[0], { type: "custom", customType: REVIEW_ENTRY, data: first });
  assert.deepEqual(readEntry(env(branch), ctx(branch)), first);

  // A reload (or a fork) reads the same bytes and publishes them for the meter.
  assert.equal(sessionReview(), first);
  await restoreReview(env(branch), ctx(branch));
  assert.deepEqual(sessionReview(), first);
  // Reading is not writing: the branch stays as long as nobody mutates the review.
  assert.equal(branch.length, 1);
});

test("the last review entry on the branch wins", () => {
  const branch: Branch = [];
  const before = entry({ seen: ["a"], sent: [] });
  const after = entry({ seen: ["a", "b"], sent: ["a"] });
  recordEntry(env(branch), ctx(branch), before);
  recordEntry(env(branch), ctx(branch), after);
  assert.deepEqual(readEntry(env(branch), ctx(branch)), after);
});

test("other custom entries and non-entry data are not state", () => {
  const branch: Branch = [
    { type: "custom", customType: "agent-note", data: { path: "/notes/x.md" } },
    { type: "message", data: entry() },
    { type: "custom", customType: REVIEW_ENTRY, data: { v: 2, slug: null } },
    { type: "custom", customType: REVIEW_ENTRY, data: "not an entry" },
  ];
  const env0 = env(branch);
  assert.equal(readEntry(env0, ctx(branch)), undefined);
  assert.equal(sessionReview(), undefined);
});

test("an unreadable newest entry falls back to the newest one that parses", () => {
  const good = entry({ seen: ["a"] });
  const branch: Branch = [
    { type: "custom", customType: REVIEW_ENTRY, data: good },
    // A field added and then removed again, or a hand-edited session file.
    { type: "custom", customType: REVIEW_ENTRY, data: { ...entry(), items: [{ id: "x" }] } },
  ];
  assert.deepEqual(readEntry(env(branch), ctx(branch)), good);
});

test("two writers that overlapped keep both their deliveries and both their ingests", async () => {
  const branch: Branch = [];
  const first = entry({
    at: "2026-11-03T21:12:12.088148037+00:00",
    seen: ["c1"],
    sent: ["c1"],
    items: [
      {
        id: "c1",
        path: "a.ts",
        startLine: 1,
        endLine: 1,
        side: "new",
        type: "issue",
        author: "N",
        body: "one",
        at: "",
      },
    ],
  });
  recordEntry(env(branch), ctx(branch), first);
  // A submit cleared the inbox for c1 and c2 while an ingest was waiting on tuicr;
  // the ingest then writes its own, older snapshot.
  const stale = entry({
    at: "2026-11-03T21:12:14.000000000+00:00",
    seen: ["c1", "c2"],
    sent: ["c1"],
    items: [
      ...first.items,
      {
        id: "c2",
        path: "b.ts",
        startLine: 2,
        endLine: 2,
        side: "new",
        type: "nit",
        author: "N",
        body: "two",
        at: "",
      },
    ],
  });
  recordEntry(env(branch), ctx(branch), stale);
  const merged = readEntry(env(branch), ctx(branch));
  assert.deepEqual(merged?.seen, ["c1", "c2"]);
  assert.deepEqual(merged?.sent, ["c1"]);
  assert.deepEqual(
    merged?.items.map((item) => item.id),
    ["c1", "c2"],
  );

  // And the other order: the surviving entry is the fresher snapshot's, with the
  // older one's deliveries kept on top of it.
  const newer = entry({
    at: "2026-11-03T21:12:16.000000000+00:00",
    seen: ["c1", "c2"],
    sent: ["c1", "c2"],
    items: stale.items,
  });
  recordEntry(env(branch), ctx(branch), newer);
  const latest = readEntry(env(branch), ctx(branch));
  assert.deepEqual(latest?.sent, ["c1", "c2"]);
  assert.equal(latest?.at, newer.at);
});

test("a review entry's optional fields are validated, not assumed", () => {
  const branch: Branch = [];
  // The argv is what tuicr is launched with, and the branch is a file on disk.
  recordEntry(env(branch), ctx(branch), {
    ...entry(),
    args: [1],
  } as never);
  assert.equal(
    readEntry(env(branch), ctx(branch)),
    undefined,
    "a mode outside C3 reads as no entry",
  );

  const pinned = entry({
    slug: null,
    args: ["-r", "a..b"],
    items: [
      {
        id: "c1",
        path: null,
        startLine: null,
        endLine: null,
        side: null,
        type: "note",
        author: null,
        body: "session level",
        at: "2026-11-03T21:12:37.844359543+00:00",
      },
    ],
  });
  const whole: Branch = [{ type: "custom", customType: REVIEW_ENTRY, data: pinned }];
  assert.deepEqual(readEntry(env(whole), ctx(whole)), pinned);
});

test("an empty branch has no review, and restoreReview publishes that", async () => {
  const branch: Branch = [];
  const read = env(branch);
  recordEntry(read, ctx(branch), entry());
  assert.ok(sessionReview() !== undefined);
  // A new session (/new) starts with an empty branch: the old review must not linger.
  const fresh: Branch = [];
  await restoreReview(env(fresh), ctx(fresh));
  assert.equal(sessionReview(), undefined);
  assert.equal(readEntry(env(fresh), ctx(fresh)), undefined);
});
