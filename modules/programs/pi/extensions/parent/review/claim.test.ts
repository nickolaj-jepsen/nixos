/**
 * A6's claim and wait reason. The claim is one file per repository (C2), and a
 * claim is live only while its process and the agent-hub's registry say so
 * (D7), so every case builds a claim out of a real pid and a real registry
 * entry rather than a timestamp. `/review take` is the only writer allowed to
 * overwrite someone else's claim (U8).
 *
 * The last cases speak the hub's protocol to a socket of their own: D10's text
 * reaches the hub as a `dialog` line and in the attach payload, and no protocol
 * version changed to carry it (U9).
 *
 * Two packages pi provides cannot be loaded outside pi: the extension host
 * resolves `@earendil-works/pi-coding-agent` itself, and the permission package
 * ships TypeScript its own loader reads. Nothing under test uses them at
 * runtime, so they are stubbed below, before the modules that import them.
 */
import { registerHooks } from "node:module";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { InboxItem, ReviewEntry } from "./types.ts";
import type { Claim } from "./types.ts";
import type { ReviewEnv } from "./env.ts";

const moduleUrl = (source: string) => `data:text/javascript,${encodeURIComponent(source)}`;

const STUBS: Record<string, string> = {
  // naming.ts's one call, reached through dialogs.ts; nothing here reads a transcript.
  "@earendil-works/pi-ai": `export const contentText = () => "";`,
  // The channels the permission extension publishes on; the stub keeps the pair in one place.
  "@gotgenes/pi-permission-system": `export const PERMISSIONS_UI_PROMPT_CHANNEL = "permissions.ui_prompt";
export const PERMISSIONS_DECISION_CHANNEL = "permissions.decision";`,
};

registerHooks({
  resolve(specifier, context, next) {
    const source = STUBS[specifier];
    if (source !== undefined) return { url: moduleUrl(source), shortCircuit: true };
    return next(specifier, context);
  },
});

// Loaded after the stubs: these are the modules that reach the packages above.
const {
  claim,
  foreignClaim,
  listed,
  readClaim,
  reviewLive,
  reviewWaitLabel,
  stale,
  takeClaim,
  waitText,
  writeClaim,
} = await import("./claim.ts");
const { createDialogs } = await import("../lib/dialogs.ts");
const { createHub } = await import("../lib/hub.ts");
const { procStart } = await import("../claude-peers/protocol.ts");
const { CLAIM_FIELDS, claimPath, reviewKey } = await import("./types.ts");
const { PERMISSIONS_UI_PROMPT_CHANNEL } = await import("@gotgenes/pi-permission-system");

const scope = { mode: "worktree" as const, args: ["-w"] };
// Real session ids: a notification shows the first eight characters.
const A = "aaaa1111-0000-4000-8000-000000000001";
const B = "bbbb2222-0000-4000-8000-000000000002";
const GONE = "cccc3333-0000-4000-8000-000000000003";
const UNLISTED = "dddd4444-0000-4000-8000-000000000004";

/**
 * A scratch world: its own home, agent dir, hub registry and runtime dir, and a
 * repository whose claim is the one under test. Nothing here reads the owner's
 * claims, registry or sockets.
 */
const world = (t: TestContext) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "review-claim-")));
  const saved: Record<string, string | undefined> = {
    HOME: process.env.HOME,
    CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR,
    PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
    XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
  };
  const root = join(dir, "repo");
  const agent = join(dir, "agent");
  const config = join(dir, "claude");
  const registry = join(config, "sessions");
  const runtime = join(dir, "run");
  for (const path of [root, agent, registry, runtime, join(dir, "home")]) {
    mkdirSync(path, { recursive: true });
  }
  process.env.HOME = join(dir, "home");
  process.env.CLAUDE_CONFIG_DIR = config;
  process.env.PI_CODING_AGENT_DIR = agent;
  process.env.XDG_RUNTIME_DIR = runtime;
  t.after(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(dir, { recursive: true, force: true });
  });
  return { dir, root, agent, registry, runtime, claims: claimPath(agent, root) };
};

/** Registers a live session the way pi and Claude Code do, in the scratch registry. */
const register = (where: { registry: string; root: string }, session: string, pid = process.pid) =>
  writeFileSync(
    join(where.registry, `${pid}.json`),
    JSON.stringify({
      sessionId: session,
      pid,
      procStart: procStart(pid),
      kind: "interactive",
      entrypoint: "pi",
      cwd: where.root,
    }),
  );

const claimant = (session: string, over: Partial<Parameters<typeof claim>[1]> = {}) => ({
  session,
  harness: "pi" as const,
  slug: null,
  scope,
  seen: [] as string[],
  ...over,
});

const claimFile = (root: string, session: string, pid: number): Claim => ({
  v: 1,
  root,
  session,
  harness: "pi",
  pid,
  slug: null,
  scope,
  seen: [],
  at: new Date().toISOString(),
});

const item = (id: string): InboxItem => ({
  id,
  path: "src/a.ts",
  startLine: 42,
  endLine: 42,
  side: "new",
  type: "issue",
  author: "Nickolaj",
  body: "guard the empty token",
  at: "2026-11-03T21:12:12.088148037+00:00",
});

const reviewEntry = (root: string, over: Partial<ReviewEntry> = {}): ReviewEntry => ({
  v: 1,
  root,
  cwd: root,
  harness: "pi",
  slug: "repo@main/staged-and-unstaged/9d1b591",
  scope,
  socket: "/run/pi-review/0123456789abcdef.sock",
  items: [item("c1"), item("c2"), item("c3"), item("c4")],
  seen: ["c1", "c2", "c3", "c4"],
  sent: [],
  progress: { reviewedCount: 5, fileCount: 7 },
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

/** A context that names a session and answers what the claim asks of it. */
const ctxFor = (cwd: string, session: string) => {
  const notices: string[] = [];
  const ctx = {
    cwd,
    mode: "tui",
    hasUI: true,
    isIdle: () => true,
    sessionManager: {
      getSessionId: () => session,
      getBranch: () => [],
      getSessionFile: () => null,
      getLeafId: () => undefined,
    },
    ui: { notify: (message: string) => notices.push(message) },
  } as unknown as ExtensionContext;
  return { ctx, notices };
};

const reviewEnv = (ctx: ExtensionContext, rest: Partial<ReviewEnv> = {}): ReviewEnv =>
  ({ pi: undefined, state: { ctx }, dialogs: undefined, hub: undefined, ...rest }) as ReviewEnv;

test("C2 a claim is written for the repository and keeps a second session out", (t) => {
  const where = world(t);
  register(where, A);
  const first = claim(where.root, claimant(A, { seen: ["c1"] }));
  assert.equal(first.held, undefined);
  assert.equal(first.claim.session, A);
  // C2, byte for byte: the fields the Claude side asserts too.
  const read = readClaim(where.root) as Claim;
  assert.deepEqual(Object.keys(read).sort(), Object.keys(CLAIM_FIELDS).sort());
  assert.deepEqual(
    { ...read, at: "the moment it was written" },
    { ...claimFile(where.root, A, process.pid), at: "the moment it was written", seen: ["c1"] },
  );
  assert.equal(Number.isNaN(Date.parse(read.at)), false, "C2's at is ISO 8601");
  assert.equal(where.claims, join(where.agent, "review-claims", `${reviewKey(where.root)}.json`));
  // C2's atomic write leaves nothing behind but the claim itself.
  assert.deepEqual(readdirSync(dirname(where.claims)), [`${reviewKey(where.root)}.json`]);

  // U8: the second session is told, and the file stays the first session's.
  const second = claim(where.root, claimant(B, { scope: { mode: "all", args: ["-A"] } }));
  assert.equal(second.held?.session, A);
  assert.equal(second.claim.session, A);
  assert.equal(readClaim(where.root)?.session, A);
});

test("D7 a refresh by the session that holds the claim merges what it has seen", (t) => {
  const where = world(t);
  register(where, A);
  claim(where.root, claimant(A, { seen: ["c1"] }));
  const again = claim(where.root, claimant(A, { seen: ["c2"], slug: "a/b/c" }));
  assert.equal(again.held, undefined);
  // Read-modify-write: the ids the first write recorded survive the second.
  assert.deepEqual(readClaim(where.root)?.seen, ["c1", "c2"]);
  assert.equal(readClaim(where.root)?.slug, "a/b/c");
});

test("D7 a claim whose process is gone is stale, whatever its registry entry says", (t) => {
  const where = world(t);
  // A child that has already exited: a real pid with nothing behind it.
  const dead = spawnSync(process.execPath, ["-e", ""]).pid;
  assert.equal(typeof dead, "number");
  writeClaim(claimFile(where.root, GONE, dead as number));
  register(where, GONE, dead as number);
  const read = readClaim(where.root);
  assert.equal(read?.pid, dead);
  assert.equal(stale(read as Claim), true, "a dead pid is stale even when the registry lists it");
  assert.equal(claim(where.root, claimant(B)).held, undefined);
  assert.equal(readClaim(where.root)?.session, B);
});

test("D7 a session the hub no longer lists is stale, and listed again once it is back", (t) => {
  const where = world(t);
  // A running pid with no registry entry: the hub does not list this session.
  writeClaim(claimFile(where.root, UNLISTED, process.pid));
  assert.equal(listed(UNLISTED), false);
  assert.equal(stale(readClaim(where.root) as Claim), true);

  register(where, UNLISTED);
  assert.equal(listed(UNLISTED), true);
  assert.equal(stale(readClaim(where.root) as Claim), false);
});

test("U8 the opener is told who holds the claim, and the holder is not itself", (t) => {
  const where = world(t);
  register(where, A);
  claim(where.root, claimant(A));
  const other = ctxFor(where.root, B);
  assert.match(
    foreignClaim(reviewEnv(other.ctx), other.ctx) ?? "",
    /^session aaaa1111 \(pid \d+\)$/,
  );
  // The same session asking about its own claim is not a foreign one.
  const own = ctxFor(where.root, A);
  assert.equal(foreignClaim(reviewEnv(own.ctx), own.ctx), undefined);
  // A stale claim blocks nobody.
  writeClaim(claimFile(where.root, GONE, 4_000_000));
  assert.equal(foreignClaim(reviewEnv(other.ctx), other.ctx), undefined);
});

test("D11 /review take rewrites the claim, keeps what it knew, and says whose it was", async (t) => {
  const where = world(t);
  register(where, A);
  claim(where.root, claimant(A, { seen: ["c1"], slug: "a/b/c" }));
  const { ctx, notices } = ctxFor(where.root, B);

  await takeClaim(reviewEnv(ctx), ctx);
  assert.match(notices[0] ?? "", /^review: claimed by session aaaa1111 \(pid \d+\); took over/);
  const taken = readClaim(where.root);
  assert.equal(taken?.session, B);
  assert.equal(taken?.pid, process.pid);
  assert.equal(taken?.scope.mode, "worktree");
  // The previous holder's slug and the ids it recorded survive the takeover.
  assert.equal(taken?.slug, "a/b/c");
  assert.deepEqual(taken?.seen, ["c1"]);

  // Taking over a repository this session already holds says so, and rewrites nothing.
  await takeClaim(reviewEnv(ctx), ctx);
  assert.equal(notices[1], "review: you hold the claim");
  assert.equal(readClaim(where.root)?.session, B);
});

test("D10 the wait text counts the inbox and the reviewer's files", () => {
  const entry = reviewEntry("/work/repo");
  assert.equal(waitText(entry), "reviewing · 4 comments, 5/7 files");
  assert.equal(waitText({ ...entry, items: [item("c1")] }), "reviewing · 1 comment, 5/7 files");
  // No listing yet: the file half is dropped rather than showing 0/0.
  assert.equal(
    waitText({ ...entry, progress: { reviewedCount: 0, fileCount: 0 } }),
    "reviewing · 4 comments",
  );
  assert.equal(
    waitText({ ...entry, items: [], progress: { reviewedCount: 0, fileCount: 0 } }),
    "reviewing · 0 comments",
  );
});

/* The hub, spoken to over a socket of its own: one line per message, as the daemon reads them. */

type Message = Record<string, unknown> & { op?: string; text?: unknown; waitingFor?: unknown };

/**
 * A server on the hub's socket path that keeps every line a session sends it,
 * and can go away and come back the way a restarted daemon does.
 */
const fakeHub = async (t: TestContext, runtime: string) => {
  const path = join(runtime, "agent-hub", "hub.sock");
  mkdirSync(dirname(path), { recursive: true });
  const lines: Message[] = [];
  const sockets: Socket[] = [];
  let server: ReturnType<typeof createServer> | undefined;
  const listen = () =>
    new Promise<void>((resolve) => {
      rmSync(path, { force: true });
      server = createServer((socket) => {
        sockets.push(socket);
        let buffered = "";
        socket.on("data", (chunk: Buffer) => {
          buffered += chunk.toString("utf8");
          for (let at = buffered.indexOf("\n"); at >= 0; at = buffered.indexOf("\n")) {
            const line = buffered.slice(0, at);
            buffered = buffered.slice(at + 1);
            if (line.trim() !== "") lines.push(JSON.parse(line) as Message);
          }
        });
      });
      server.listen(path, resolve);
    });
  const close = async () => {
    for (const socket of sockets.splice(0)) socket.destroy();
    await new Promise<void>((resolve) => {
      if (server === undefined) return resolve();
      const closing = server;
      server = undefined;
      closing.close(() => resolve());
    });
  };
  await listen();
  t.after(async () => {
    await close();
    rmSync(path, { force: true });
  });
  const attaches = () => lines.filter((line) => line.op === "attach").length;
  /** Down and up again: the session's next attach is a fresh one. */
  const restart = async () => {
    await close();
    await listen();
  };
  return { path, lines, attaches, restart };
};

/** A pi stand-in: the handlers the chrome registers, and the events a session emits. */
const fakePi = () => {
  const handlers = new Map<string, ((event: unknown, ctx?: unknown) => unknown)[]>();
  const channels = new Map<string, ((data: unknown) => void)[]>();
  return {
    on(name: string, handler: (event: unknown, ctx?: unknown) => unknown) {
      handlers.set(name, [...(handlers.get(name) ?? []), handler]);
      return () => {};
    },
    events: {
      on(channel: string, handler: (data: unknown) => void) {
        channels.set(channel, [...(channels.get(channel) ?? []), handler]);
        return () => {};
      },
    },
    emit(name: string, event: unknown, ctx: unknown) {
      for (const handler of handlers.get(name) ?? []) handler(event, ctx);
    },
    publish(channel: string, data: unknown) {
      for (const handler of channels.get(channel) ?? []) handler(data);
    },
  };
};

/** Polls `ready` until it holds; `tries` of 10 ms, so the default waits 4 s. */
const until = async (what: string, ready: () => boolean, tries = 400) => {
  for (let at = 0; at < tries; at += 1) {
    if (ready()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for ${what}`);
};

const lastOp = (lines: Message[], op: string) =>
  [...lines].reverse().find((line) => line.op === op);

/** The chrome's dialogs and hub, on the stand-in pi, with the review's own source added. */
const wired = (ctx: ExtensionContext) => {
  const pi = fakePi();
  const dialogs = createDialogs(pi as unknown as ExtensionAPI);
  const hub = createHub(pi as unknown as ExtensionAPI, dialogs);
  const env = reviewEnv(ctx, {
    pi: pi as unknown as ExtensionAPI,
    dialogs,
    hub,
    state: { ctx },
  });
  return { pi, env };
};

test("D10 the hub's dialog line carries the review's text, and a settled run keeps it", async (t) => {
  const where = world(t);
  const hub = await fakeHub(t, where.runtime);
  const { ctx } = ctxFor(where.root, A);
  register(where, A);
  const { pi, env } = wired(ctx);

  pi.emit("session_start", {}, ctx);
  await until("the attach", () => lastOp(hub.lines, "attach") !== undefined);
  const attach = lastOp(hub.lines, "attach") as Message;
  assert.equal(attach.version, 3, "U9: the hub is spoken to on the version it already knows");
  assert.equal(attach.waitingFor, null);
  assert.equal(
    hub.lines.some((line) => line.op === "dialog"),
    false,
  );

  // The review starts: the label is pushed here, before the TUI is suspended.
  reviewLive(env, reviewEntry(where.root));
  assert.equal(reviewWaitLabel(env), "reviewing · 4 comments, 5/7 files");
  await until(
    "the review's dialog line",
    () => lastOp(hub.lines, "dialog")?.text === "reviewing · 4 comments, 5/7 files",
  );
  assert.deepEqual(lastOp(hub.lines, "dialog"), {
    op: "dialog",
    text: "reviewing · 4 comments, 5/7 files",
  });

  // A permission ask takes the label's place, and a settled run clears the ask
  // but not the review, which `during` alone would have taken with it.
  pi.publish(PERMISSIONS_UI_PROMPT_CHANNEL, {
    requestId: "ask-1",
    request: { toolName: "bash" },
    value: "rm -rf build",
  });
  await until(
    "the ask's dialog line",
    () => lastOp(hub.lines, "dialog")?.text === "bash: rm -rf build",
  );
  pi.emit("agent_settled", {}, ctx);
  await until(
    "the review's label back after the run settled",
    () => lastOp(hub.lines, "dialog")?.text === "reviewing · 4 comments, 5/7 files",
  );

  // The review ends: the hub is told there is nothing to wait on, and the claim is released.
  reviewLive(env, undefined);
  assert.equal(reviewWaitLabel(env), undefined);
  await until("the cleared dialog line", () => lastOp(hub.lines, "dialog")?.text === null);
  assert.equal(readClaim(where.root), undefined);
  pi.emit("session_shutdown", {}, ctx);
});

test("D10 clearing a review's label at idle says idle, not busy", async (t) => {
  const where = world(t);
  const daemon = await fakeHub(t, where.runtime);
  const { ctx } = ctxFor(where.root, A);
  register(where, A);
  const { pi, env } = wired(ctx);

  pi.emit("session_start", {}, ctx);
  await until("the first attach", () => daemon.attaches() === 1);
  reviewLive(env, reviewEntry(where.root));
  await until(
    "the review's dialog line",
    () => lastOp(daemon.lines, "dialog")?.text === "reviewing · 4 comments, 5/7 files",
  );
  // The review ends with no turn running: the hub must not be told the session is busy.
  reviewLive(env, undefined);
  await until("the cleared dialog line", () => lastOp(daemon.lines, "dialog")?.text === null);
  await daemon.restart();
  await until("the second attach", () => daemon.attaches() === 2, 800);
  const attach = lastOp(daemon.lines, "attach") as Message;
  assert.equal(attach.waitingFor, null);
  assert.equal(attach.status, "idle", "a cleared label at idle is not a running turn");
  pi.emit("session_shutdown", {}, ctx);
});

test("D10 a hub that reattaches during a review hears the text in the attach payload", async (t) => {
  const where = world(t);
  const daemon = await fakeHub(t, where.runtime);
  const { ctx } = ctxFor(where.root, A);
  register(where, A);
  const { pi, env } = wired(ctx);
  const text = "reviewing · 4 comments, 5/7 files";

  pi.emit("session_start", {}, ctx);
  await until("the first attach", () => daemon.attaches() === 1);
  assert.equal((lastOp(daemon.lines, "attach") as Message).waitingFor, null);

  // The review is live, and then the daemon restarts: its next attach is the only
  // way it can learn what the session waits on, since the dialog line predates it.
  reviewLive(env, reviewEntry(where.root));
  await until("the review's dialog line", () => lastOp(daemon.lines, "dialog")?.text === text);
  await daemon.restart();
  // The client retries a lost connection every 5 s.
  await until("the second attach", () => daemon.attaches() === 2, 800);
  const attach = lastOp(daemon.lines, "attach") as Message;
  assert.equal(attach.waitingFor, text);
  assert.equal(attach.status, "waiting");
  pi.emit("session_shutdown", {}, ctx);
});
