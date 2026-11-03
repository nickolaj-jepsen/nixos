/**
 * A2's lifecycle, minus the parts that need a terminal: the socket check, the
 * pid file, and the order D8 asks for (save through the pty, then signal).
 *
 * The real thing — a dtach-hosted tuicr, the hop out of pi's TUI, the save, the
 * adoption after a crash — is `scenario/dtach.sh`, because none of it can be
 * observed without a pty.
 */
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  type EndIo,
  alive,
  attach,
  dtachArgv,
  finish,
  liveReviews,
  parseActiveSessions,
  start,
} from "./tuicr.ts";

const SLUG = "repo@main/staged-and-unstaged/02a6d85";

/** A scratch tuicr store: session files with a repo, and the pid file beside them. */
const store = () => {
  const root = mkdtempSync(join(tmpdir(), "tuicr-life-"));
  const data = join(root, "data");
  const sessions = join(data, "tuicr", "reviews", "sessions");
  mkdirSync(sessions, { recursive: true });
  const session = (name: string, repo: string) => {
    const path = join(sessions, name);
    writeFileSync(path, JSON.stringify({ version: "1.3", repo_path: `${repo}/` }));
    return path;
  };
  const pidFile = (sessions_: unknown[]) =>
    writeFileSync(
      join(data, "tuicr", "reviews", "active_sessions.json"),
      JSON.stringify({ version: "1.0", sessions: sessions_ }),
    );
  return { root, data, session, pidFile, sessions };
};

const scratch = (name: string) => mkdtempSync(join(tmpdir(), `tuicr-test-${name}-`));

test("a review is attachable while its socket exists", () => {
  const root = scratch("socket");
  const socket = join(root, "pi-review", "0123456789abcdef.sock");
  assert.equal(alive(socket), false);
  mkdirSync(dirname(socket), { recursive: true });
  writeFileSync(socket, "");
  assert.equal(alive(socket), true);
  rmSync(root, { recursive: true, force: true });
});

test("the pid file keeps the sessions it can use and drops the rest", () => {
  const reviews = parseActiveSessions(
    JSON.stringify({
      version: "1.0",
      sessions: [
        {
          pid: 41,
          slug: SLUG,
          path: "/data/sessions/aa.json",
          last_seen_at: "2026-11-03T21:00:00Z",
        },
        { pid: "42", slug: SLUG, path: "/data/sessions/bb.json" },
        { pid: 43, slug: "", path: "/data/sessions/cc.json" },
        { pid: 44, slug: SLUG, path: "" },
        { pid: 45, slug: SLUG, path: "/data/sessions/dd.json" },
      ],
    }),
  );
  assert.deepEqual(
    reviews.map((review) => review.pid),
    [41, 45],
  );
  // No usable timestamp reads as old, so a stale entry cannot pass as fresh.
  assert.equal(reviews[1].at, 0);
  assert.deepEqual(parseActiveSessions("not json"), []);
  assert.deepEqual(parseActiveSessions("[]"), []);
  assert.deepEqual(parseActiveSessions('{"sessions": "nope"}'), []);
});

test("liveReviews answers the running tuicr of this repository", () => {
  const { data, session, pidFile } = store();
  const repoA = scratch("repo-a");
  const repoB = scratch("repo-b");
  const now = Date.parse("2026-11-03T22:00:00Z");
  const mine = session("a.json", repoA);
  const missing = join(data, "tuicr", "reviews", "sessions", "gone.json");
  pidFile([
    {
      pid: 11,
      slug: "a@main/staged-and-unstaged/1111111",
      path: mine,
      last_seen_at: "2026-11-03T21:59:00Z",
    },
    { pid: 12, slug: "a@main/unstaged/1111111", path: mine, last_seen_at: "2026-11-03T21:59:00Z" },
    {
      pid: 13,
      slug: "b@main/staged-and-unstaged/2222222",
      path: session("b.json", repoB),
      last_seen_at: "2026-11-03T21:59:30Z",
    },
    // Fresh enough and running, but last seen 13 hours ago: tuicr calls that gone.
    {
      pid: 14,
      slug: "a@main/commits/1111111..1111111",
      path: mine,
      last_seen_at: "2026-11-02T09:00:00Z",
    },
    // The session file a crashed review left behind is not there to read.
    {
      pid: 15,
      slug: "a@main/staged-and-unstaged/3333333",
      path: missing,
      last_seen_at: "2026-11-03T21:59:00Z",
    },
  ]);

  const running = (pid: number) => pid !== 12;
  const reviews = liveReviews({ data, roots: [repoA], now, running });
  assert.deepEqual(
    reviews.map((review) => review.pid),
    [11],
  );

  // Without a repository both are live, newest first.
  assert.deepEqual(
    liveReviews({ data, now, running }).map((review) => review.pid),
    [13, 11],
  );
});

test("finish saves through the socket before it signals the pid (D8)", async () => {
  const root = scratch("finish");
  const socket = join(root, "review.sock");
  writeFileSync(socket, "");
  const calls: string[] = [];
  const io: EndIo = {
    running: () => true,
    save: async (path) => {
      calls.push(`save ${path}`);
    },
    terminate: async (pid, path) => {
      calls.push(`terminate ${pid} ${path}`);
    },
  };
  assert.equal(await finish(socket, 42, io), true);
  assert.deepEqual(calls, [`save ${socket}`, `terminate 42 ${socket}`]);
  rmSync(root, { recursive: true, force: true });
});

test("finish is a no-op once the review is gone (U7's idempotence)", async () => {
  const root = scratch("twice");
  const socket = join(root, "review.sock");
  writeFileSync(socket, "");
  const calls: string[] = [];
  let running = true;
  const io: EndIo = {
    running: () => running,
    save: async () => {
      calls.push("save");
    },
    terminate: async () => {
      calls.push("terminate");
      running = false;
      rmSync(socket, { force: true });
    },
  };
  assert.equal(await finish(socket, 42, io), true);
  assert.equal(await finish(socket, 42, io), false);
  assert.deepEqual(calls, ["save", "terminate"]);
  rmSync(root, { recursive: true, force: true });
});

test("finish saves a review whose pid is unknown and signals nothing", async () => {
  const root = scratch("nopid");
  const socket = join(root, "review.sock");
  writeFileSync(socket, "");
  const calls: string[] = [];
  const io: EndIo = {
    running: () => false,
    save: async () => {
      calls.push("save");
    },
    terminate: async () => {
      calls.push("terminate");
    },
  };
  assert.equal(await finish(socket, undefined, io), true);
  assert.deepEqual(calls, ["save"]);
  assert.equal(await finish(join(root, "nothing.sock"), undefined, io), false);
  assert.deepEqual(calls, ["save"]);
  rmSync(root, { recursive: true, force: true });
});

/** The TUI hangar pi hands a command: enough of it to see the suspend and its return. */
const tuiContext = (custom: () => Promise<number | null>) =>
  ({ mode: "tui", hasUI: true, ui: { custom } }) as unknown as ExtensionContext;

test("start makes the socket's directory and suspends pi's TUI through ui.custom", async () => {
  const root = scratch("start");
  const socket = join(root, "pi-review", "0123456789abcdef.sock");
  const spec = { cwd: root, socket, argv: ["-w"] };
  let asked = 0;
  const ctx = tuiContext(async () => {
    asked += 1;
    return 7;
  });
  assert.equal(await start(ctx, spec), 7);
  assert.equal(asked, 1);
  assert.equal(existsSync(dirname(socket)), true);
  rmSync(root, { recursive: true, force: true });
});

test("attach suspends like start, and both refuse a session without a TUI", async () => {
  const root = scratch("attach");
  const spec = { cwd: root, socket: join(root, "review.sock"), argv: ["-w"] };
  assert.equal(
    await attach(
      tuiContext(async () => 0),
      spec,
    ),
    0,
  );
  const headless = { mode: "print", hasUI: false, ui: { custom: async () => 0 } };
  assert.equal(await attach(headless as unknown as ExtensionContext, spec), null);
  assert.equal(await start(headless as unknown as ExtensionContext, spec), null);
  rmSync(root, { recursive: true, force: true });
});

test("the hop is dtach -A with winch redraw and ^G to come back (C6)", () => {
  assert.deepEqual(dtachArgv({ cwd: "/work/repo", socket: "/run/x.sock", argv: ["-w"] }), [
    "-A",
    "/run/x.sock",
    "-r",
    "winch",
    "-e",
    "^G",
    "tuicr",
    "-w",
  ]);
  // The pinned scope's argv reaches tuicr as elements, never as a shell string (B2).
  assert.deepEqual(
    dtachArgv({ cwd: "/work/repo", socket: "/run/x.sock", argv: ["pr", "owner/repo#12"] }).slice(
      -2,
    ),
    ["pr", "owner/repo#12"],
  );
});
