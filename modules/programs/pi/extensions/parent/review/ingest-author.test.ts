/**
 * A6's half of `/rv` ingest (D25): the review tour's comments are seeded in the
 * owner's own tuicr session under the author `Flow`, and the batch text omits
 * authors, so a tour comment left in would come back to the model as review
 * work. Ingest drops them and keeps the owner's.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";
import { TOUR_AUTHOR, ingestWith, type TuicrSource } from "./ingest.ts";
import { batchText } from "./types.ts";
import type { ReviewEntry } from "./types.ts";

const env = { pi: { appendEntry: () => {} } } as unknown as ReviewEnv;

const ctx = (cwd: string, session: string) =>
  ({
    cwd,
    sessionManager: { getSessionId: () => session, getBranch: () => [] },
  }) as unknown as ExtensionContext;

const fixture = (name: string) =>
  readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");

const SLUG = "repo@main/staged-and-unstaged/02a6d85";
const ROOT = "/work/repo";

/** One owner comment and one the tour seeded into the same session. */
const COMMENTS = JSON.stringify([
  {
    id: "owner-1",
    location: "a.ts:2",
    path: "a.ts",
    start_line: 2,
    end_line: 2,
    side: "new",
    comment_type: "issue",
    author: "Nickolaj",
    lifecycle_state: "local_draft",
    created_at: "2026-11-03T22:12:37.844359543+00:00",
    content: "this drops the old key",
  },
  {
    id: "tour-1",
    location: "review",
    path: null,
    start_line: null,
    end_line: null,
    side: null,
    comment_type: "note",
    author: TOUR_AUTHOR,
    lifecycle_state: "local_draft",
    created_at: "2026-11-03T22:12:40.000000000+00:00",
    content: "read a.ts first: the value moves",
  },
]);

const source = (comments = COMMENTS): TuicrSource => ({
  list: async () => ({ code: 0, stdout: fixture("list-staged-and-unstaged.json") }),
  comments: async () => ({ code: 0, stdout: comments }),
});

const entry = (over: Partial<ReviewEntry> = {}): ReviewEntry => ({
  v: 1,
  root: ROOT,
  cwd: ROOT,
  harness: "pi",
  slug: SLUG,
  args: ["-w"],
  items: [],
  seen: [],
  sent: [],
  progress: { reviewedCount: 0, fileCount: 0 },
  at: "2026-11-03T22:12:12.088148037+00:00",
  ...over,
});

test("the tour's author is the name flow_tour signs with", () => {
  assert.equal(TOUR_AUTHOR, "Flow");
});

test("D25 a Flow comment reaches neither the fresh items nor the batch", async () => {
  const next = await ingestWith(env, ctx(ROOT, "s-tour"), entry(), source());
  assert.ok(next !== undefined);
  assert.deepEqual(
    next.items.map((item) => item.id),
    ["owner-1"],
  );
  // It is still read once: a repeat ingest must not read it again.
  assert.deepEqual([...next.seen].sort(), ["owner-1", "tour-1"]);

  const batch = batchText(SLUG, ROOT, next.items);
  assert.match(batch, /this drops the old key/);
  assert.ok(!batch.includes("read a.ts first"), batch);
});

test("a session holding only tour comments records nothing", async () => {
  const only = JSON.stringify([JSON.parse(COMMENTS)[1]]);
  assert.equal(await ingestWith(env, ctx(ROOT, "s-tour-only"), undefined, source(only)), undefined);
});

test("a repeat ingest keeps the owner's item and stays put", async () => {
  const first = await ingestWith(env, ctx(ROOT, "s-tour-repeat"), entry(), source());
  const again = await ingestWith(env, ctx(ROOT, "s-tour-repeat"), first, source());
  assert.equal(again, first);
});
