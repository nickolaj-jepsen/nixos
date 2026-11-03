/**
 * A3's ingest against tuicr's recorded output: the fixture cases in HANDOFF
 * (an empty list, a missing session, `+00:00` timestamps, a PR slug, the
 * commits-and-worktree slug, a comment with no path, `start_line ==
 * end_line`, `progress`), the two uncertain mechanisms (M2's wait and its
 * newest-by-time fallback, D6's sessions that went active), and one case
 * against the installed binary when there is one.
 *
 * The fixtures are what 0.28.0 printed, with the scratch paths renamed
 * (notes/tuicr-dtach.md §1). Nothing here starts a tuicr process except the
 * last case, and that one reads an empty store.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ReviewEnv } from "./env.ts";
import { type TuicrResult, type TuicrSource, cliTuicr, ingestWith } from "./ingest.ts";
import { type ReviewEntry, socketPath } from "./types.ts";

/** `recordEntry` is A5's stub today, so every assertion is on what ingest returns (C1). */
const env = {} as ReviewEnv;

const ctx = (cwd: string, session: string) =>
  ({ cwd, sessionManager: { getSessionId: () => session } }) as unknown as ExtensionContext;

const fixture = (name: string) =>
  readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");

/** A tuicr that answers from the committed fixtures; a slug it does not know exits 1, as tuicr does. */
const source = (options: { list: string; comments?: Record<string, string> }) => {
  const calls: string[] = [];
  const answer: TuicrSource & { calls: string[] } = {
    calls,
    list: async (root) => {
      calls.push(`list ${root}`);
      return { code: 0, stdout: options.list };
    },
    comments: async (_root, slug) => {
      calls.push(`comments ${slug}`);
      const body = options.comments?.[slug];
      return body === undefined ? { code: 1, stdout: "" } : { code: 0, stdout: body };
    },
  };
  return answer;
};

const SLUG = "repo@main/staged-and-unstaged/02a6d85";

const entry = (over: Partial<ReviewEntry> = {}): ReviewEntry => ({
  v: 1,
  root: "/work/repo",
  cwd: "/work/repo",
  harness: "pi",
  slug: SLUG,
  scope: { mode: "worktree", args: ["-w"] },
  socket: "/run/user/1000/pi-review/0123456789abcdef.sock",
  items: [],
  seen: [],
  sent: [],
  progress: { reviewedCount: 0, fileCount: 0 },
  at: "2026-11-03T22:12:12.088148037+00:00",
  ...over,
});

/** A scratch directory and a socket under it, as a review would leave one (C6, A2). */
const scratch = (t: { after: (fn: () => void) => void }) => {
  const dir = mkdtempSync(join(tmpdir(), "pi-review-ingest-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const runtime = join(dir, "run");
  mkdirSync(join(runtime, "pi-review"), { recursive: true });
  const saved = process.env.XDG_RUNTIME_DIR;
  process.env.XDG_RUNTIME_DIR = runtime;
  t.after(() => {
    if (saved === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = saved;
  });
  const root = realpathSync(dir);
  return { dir, root, live: () => writeFileSync(socketPath(runtime, root), "") };
};

test("a repository with no sessions reads `[]` and ingests nothing", async (t) => {
  const { dir, root } = scratch(t);
  const tuicr = source({ list: fixture("list-empty.json") });
  assert.equal(await ingestWith(env, ctx(dir, "s-empty"), undefined, tuicr), undefined);
  assert.deepEqual(tuicr.calls, [`list ${root}`]);
});

test("a session tuicr cannot find exits 1 and leaves the entry alone", async () => {
  const before = entry({
    slug: "repo@main/staged-and-unstaged/fffffff",
    seen: ["kept"],
    progress: { reviewedCount: 1, fileCount: 2 },
  });
  const tuicr = source({ list: fixture("list-empty.json") });
  const next = await ingestWith(env, ctx("/work/repo", "s-missing"), before, tuicr);
  assert.deepEqual(tuicr.calls.slice(1), [`comments ${before.slug}`]);
  // Nothing changed, so nothing was recorded and the old entry is still the state.
  assert.equal(next, before);
  // A listing that no longer reports progress is not the same as zero progress.
  assert.deepEqual(next?.progress, { reviewedCount: 1, fileCount: 2 });
});

test("C4 a comment maps with its `+00:00` timestamp and its fields", async () => {
  const tuicr = source({
    list: fixture("list-staged-and-unstaged.json"),
    comments: { [SLUG]: fixture("comments-staged-and-unstaged.json") },
  });
  const next = await ingestWith(env, ctx("/work/repo", "s-comments"), entry(), tuicr);
  assert.ok(next !== undefined);
  const byId = new Map(next.items.map((item) => [item.id, item]));
  // A review-level comment has no path, no line and no side: tuicr prints nulls.
  assert.deepEqual(byId.get("a6a1cca9-fcdb-42d7-9ee6-d7d6dfd3aeb3"), {
    id: "a6a1cca9-fcdb-42d7-9ee6-d7d6dfd3aeb3",
    path: null,
    startLine: null,
    endLine: null,
    side: null,
    type: "note",
    author: "Nickolaj",
    body: "session level: check the migration",
    at: "2026-11-03T22:12:37.844359543+00:00",
  });
  // `start_line == end_line` stays a line, not a range.
  const single = byId.get("8d5d5680-fbc4-469d-a4d6-e2a1ab6cd636");
  assert.equal(single?.startLine, 2);
  assert.equal(single?.endLine, 2);
  assert.equal(single?.side, "new");
  // A range on the old side keeps both ends and the side.
  const range = byId.get("54f63cdd-cab0-476c-98e4-3bdf231154ba");
  assert.deepEqual([range?.startLine, range?.endLine, range?.side], [3, 5, "old"]);
  // A file comment has a path and no line.
  const file = byId.get("fdb4b211-dbfb-43ea-981c-bb3ba3728b31");
  assert.deepEqual([file?.path, file?.startLine], ["b.txt", null]);
  for (const item of next.items) assert.match(item.at, /\+00:00$/);
  // tuicr's order is the inbox's order, and the batch numbers follow it (C5).
  assert.deepEqual(
    next.items.map((item) => item.id),
    [
      "a6a1cca9-fcdb-42d7-9ee6-d7d6dfd3aeb3",
      "8d5d5680-fbc4-469d-a4d6-e2a1ab6cd636",
      "54f63cdd-cab0-476c-98e4-3bdf231154ba",
      "fdb4b211-dbfb-43ea-981c-bb3ba3728b31",
    ],
  );
  assert.deepEqual(
    next.seen,
    next.items.map((item) => item.id),
  );
});

test("C1 progress comes from `review list`", async () => {
  const tuicr = source({
    list: fixture("list-staged-and-unstaged.json"),
    comments: { [SLUG]: fixture("comments-staged-and-unstaged.json") },
  });
  const next = await ingestWith(env, ctx("/work/repo", "s-progress"), entry(), tuicr);
  assert.deepEqual(next?.progress, { reviewedCount: 1, fileCount: 2 });
  assert.equal(next?.slug, SLUG);
});

test("a PR slug is read like any other session", async () => {
  const slug = "gh:agavra/tuicr/pr/125";
  const tuicr = source({
    list: fixture("list-pr.json"),
    comments: { [slug]: fixture("comments-pr.json") },
  });
  const next = await ingestWith(env, ctx("/work/repo", "s-pr"), entry({ slug }), tuicr);
  assert.equal(next?.items.length, 2);
  assert.deepEqual(next?.progress, { reviewedCount: 1, fileCount: 3 });
});

test("a staged-and-unstaged-and-commits/… slug is read like any other session", async () => {
  const slug = "repo@main/staged-and-unstaged-and-commits/02a6d85..76bb164";
  const tuicr = source({
    list: fixture("list-staged-and-unstaged-and-commits.json"),
    comments: { [slug]: fixture("comments-staged-and-unstaged-and-commits.json") },
  });
  const next = await ingestWith(env, ctx("/work/repo", "s-commits"), entry({ slug }), tuicr);
  assert.equal(next?.items.length, 1);
  assert.equal(next?.items[0]?.body, "this line is only in the commit");
  assert.deepEqual(next?.progress, { reviewedCount: 1, fileCount: 2 });
});

test("only the ids absent from seen arrive, and a repeat ingest records nothing", async () => {
  const all = JSON.parse(fixture("comments-staged-and-unstaged.json")) as { id: string }[];
  const tuicr = source({
    list: fixture("list-staged-and-unstaged.json"),
    comments: { [SLUG]: fixture("comments-staged-and-unstaged.json") },
  });
  const first = await ingestWith(
    env,
    ctx("/work/repo", "s-seen"),
    entry({ seen: [all[1].id] }),
    tuicr,
  );
  assert.equal(first?.items.length, 3);
  // Seen keeps what it had and then what arrived, so nothing is read twice.
  assert.deepEqual([...(first?.seen ?? [])].sort(), all.map((comment) => comment.id).sort());
  assert.ok(!first?.items.some((item) => item.id === all[1].id));

  const again = await ingestWith(
    env,
    ctx("/work/repo", "s-seen"),
    first,
    source({
      list: fixture("list-staged-and-unstaged.json"),
      comments: { [SLUG]: fixture("comments-staged-and-unstaged.json") },
    }),
  );
  assert.equal(again, first);
});

test("an empty orphan is never read, even when it is the newest session", async (t) => {
  const { dir } = scratch(t);
  const tuicr = source({ list: fixture("list-orphans.json") });
  assert.equal(await ingestWith(env, ctx(dir, "s-orphan"), undefined, tuicr), undefined);
  assert.deepEqual(
    tuicr.calls.filter((call) => call.startsWith("comments")),
    [],
  );
});

test("M2 waits for a review that is still registering itself", async (t) => {
  const { dir, live } = scratch(t);
  live();
  const bodies = [fixture("list-empty.json"), fixture("list-staged-and-unstaged.json")];
  let calls = 0;
  const tuicr: TuicrSource = {
    // tuicr writes its session file a few seconds after launch; the first look sees nothing.
    list: async () => ({ code: 0, stdout: bodies[Math.min(calls++, 1)] }),
    comments: async () => ({ code: 0, stdout: fixture("comments-staged-and-unstaged.json") }),
  };
  const started = Date.now();
  const next = await ingestWith(env, ctx(dir, "s-poll"), undefined, tuicr);
  assert.ok(calls >= 2);
  assert.ok(Date.now() - started >= 200);
  assert.equal(next?.items.length, 4);
  assert.equal(next?.slug, SLUG);
});

test("M2 without an active session: the newest with comments, and only while a socket exists", async (t) => {
  const { dir, live } = scratch(t);
  // `review list` returns newest first: the empty orphan leads the ended review.
  const mixed = JSON.stringify([
    ...(JSON.parse(fixture("list-orphans.json")) as unknown[]),
    ...(JSON.parse(fixture("list-staged-and-unstaged-ended.json")) as unknown[]),
  ]);
  const answers = {
    list: mixed,
    comments: { [SLUG]: fixture("comments-staged-and-unstaged.json") },
  };
  // No review is running: an old session's comments are not a new inbox.
  assert.equal(await ingestWith(env, ctx(dir, "s-quiet"), undefined, source(answers)), undefined);
  live();
  const next = await ingestWith(env, ctx(dir, "s-fallback"), undefined, source(answers));
  assert.equal(next?.slug, SLUG);
  assert.equal(next?.items.length, 4);
});

test("D6 a session that went active is still read once it has ended", async (t) => {
  const { dir } = scratch(t);
  const slug = "repo@main/staged-and-unstaged-and-commits/02a6d85..76bb164";
  // `review list` returns newest first, both sessions of this repository at once.
  const both = (newest: string, newestState: string) =>
    JSON.stringify([
      ...(JSON.parse(fixture(newestState)) as unknown[]),
      ...(JSON.parse(fixture(newest)) as unknown[]),
    ]);
  const first = await ingestWith(
    env,
    ctx(dir, "s-active"),
    entry({ slug }),
    source({
      // The pinned review is over; another one went live beside it.
      list: both("list-staged-and-unstaged-and-commits.json", "list-staged-and-unstaged.json"),
      comments: {
        [SLUG]: fixture("comments-staged-and-unstaged.json"),
        [slug]: fixture("comments-staged-and-unstaged-and-commits.json"),
      },
    }),
  );
  assert.equal(first?.items.length, 5);
  assert.equal(first?.slug, slug);

  const second = await ingestWith(
    env,
    ctx(dir, "s-active"),
    first,
    source({
      // It ended too, with one more comment on it.
      list: both(
        "list-staged-and-unstaged-and-commits.json",
        "list-staged-and-unstaged-ended.json",
      ),
      comments: {
        [SLUG]: fixture("comments-staged-and-unstaged-ended.json"),
        [slug]: fixture("comments-staged-and-unstaged-and-commits.json"),
      },
    }),
  );
  assert.equal(second?.items.length, 6);
  assert.equal(second?.items.at(-1)?.body, "does this need a test?");
  assert.equal(second?.progress.reviewedCount, 1);
});

test("output that is not the JSON array reads as nothing", async () => {
  const before = entry();
  const tuicr: TuicrSource = {
    list: async () => ({ code: 0, stdout: "warning: something\n[]" }),
    comments: async () => ({ code: 0, stdout: "not json" }) as TuicrResult,
  };
  assert.equal(await ingestWith(env, ctx("/work/repo", "s-garbage"), before, tuicr), before);
});

const hasTuicr = (): string | undefined => {
  try {
    execFileSync("tuicr", ["--version"], { stdio: "ignore" });
    return undefined;
  } catch {
    return "tuicr is not on PATH";
  }
};

test("the installed binary answers in the shapes ingest reads", { skip: hasTuicr() }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "pi-review-cli-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  // A scratch store: the owner's reviews are not this test's to read or write.
  const saved = { data: process.env.XDG_DATA_HOME, config: process.env.XDG_CONFIG_HOME };
  process.env.XDG_DATA_HOME = join(dir, "data");
  process.env.XDG_CONFIG_HOME = join(dir, "config");
  mkdirSync(process.env.XDG_DATA_HOME, { recursive: true });
  mkdirSync(process.env.XDG_CONFIG_HOME, { recursive: true });
  t.after(() => {
    for (const [key, value] of [
      ["XDG_DATA_HOME", saved.data],
      ["XDG_CONFIG_HOME", saved.config],
    ] as const) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });

  const listed = await cliTuicr.list(dir);
  assert.equal(listed.code, 0);
  assert.deepEqual(JSON.parse(listed.stdout), []);
  const missing = await cliTuicr.comments(dir, SLUG);
  assert.equal(missing.code, 1);
  assert.deepEqual(JSON.parse(missing.stdout === "" ? "[]" : missing.stdout), []);
  // And an ingest over a store with no sessions records nothing.
  assert.equal(await ingestWith(env, ctx(dir, "s-real"), undefined, cliTuicr), undefined);
});
