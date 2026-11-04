/**
 * The opener's own half: which session the review it just opened ended up as.
 * tuicr keeps its slug on the pty, so the only way to learn it is the newest
 * session it touched since the launch (M2). Everything that needs a terminal —
 * the hop out of pi's TUI, quitting tuicr, the ingest that follows — is
 * `scenario/smoke.sh` and friends.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Listing } from "./ingest.ts";
import { latestSession } from "./tuicr.ts";

const at = (iso: string) => Date.parse(iso);

const session = (over: Partial<Listing> = {}): Listing => ({
  root: "/work/repo",
  slug: "repo@main/staged-and-unstaged/9d1b591",
  active: false,
  comments: 0,
  progress: { reviewedCount: 1, fileCount: 2 },
  updated: at("2026-11-04T09:00:00Z"),
  ...over,
});

test("the review just opened is the newest session tuicr touched", () => {
  const launched = at("2026-11-04T09:00:00Z");
  const older = session({ slug: "repo@main/older", updated: at("2026-11-04T08:00:00Z") });
  const ours = session({ slug: "repo@main/ours", updated: at("2026-11-04T09:00:03Z") });
  assert.equal(latestSession([older, ours], launched)?.slug, "repo@main/ours");
});

test("a session older than the launch is not adopted", () => {
  const launched = at("2026-11-04T09:00:00Z");
  const older = session({ updated: at("2026-11-04T08:59:00Z") });
  assert.equal(latestSession([older], launched), undefined);
});

test("a review the owner backed out of wrote nothing to adopt", () => {
  assert.equal(latestSession([], at("2026-11-04T09:00:00Z")), undefined);
});

test("the review's own listing answers with its progress", () => {
  const launched = at("2026-11-04T09:00:00Z");
  const ours = session({
    updated: at("2026-11-04T09:00:02Z"),
    progress: { reviewedCount: 3, fileCount: 7 },
  });
  assert.deepEqual(latestSession([ours], launched)?.progress, { reviewedCount: 3, fileCount: 7 });
});
