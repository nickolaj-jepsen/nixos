/**
 * D10's wait reason: the text the review gives the hub while it holds the
 * terminal, and the two ways the hub hears it.
 *
 * The cases speak the hub's protocol to a socket of their own: the text reaches
 * the hub as a `dialog` line and in the attach payload, and no protocol version
 * changed to carry it (U9).
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
const { reviewLive, reviewWaitLabel, waitText } = await import("./live.ts");
const { createDialogs } = await import("../lib/dialogs.ts");
const { createHub } = await import("../lib/hub.ts");
const { procStart } = await import("../claude-peers/protocol.ts");
const { PERMISSIONS_UI_PROMPT_CHANNEL } = await import("@gotgenes/pi-permission-system");

const scope = { mode: "worktree" as const, args: ["-w"] };
// Real session ids: a notification shows the first eight characters.
const A = "aaaa1111-0000-4000-8000-000000000001";
const B = "bbbb2222-0000-4000-8000-000000000002";
const GONE = "cccc3333-0000-4000-8000-000000000003";
const UNLISTED = "dddd4444-0000-4000-8000-000000000004";

/**
 * A scratch world: its own home, hub registry and runtime dir, and the
 * checkout a review runs in. Nothing here reads the owner's registry or
 * sockets.
 */
const world = (t: TestContext) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "review-live-")));
  const saved: Record<string, string | undefined> = {
    HOME: process.env.HOME,
    CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR,
    XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
  };
  const root = join(dir, "repo");
  const config = join(dir, "claude");
  const registry = join(config, "sessions");
  const runtime = join(dir, "run");
  for (const path of [root, registry, runtime, join(dir, "home")]) {
    mkdirSync(path, { recursive: true });
  }
  process.env.HOME = join(dir, "home");
  process.env.CLAUDE_CONFIG_DIR = config;
  process.env.XDG_RUNTIME_DIR = runtime;
  t.after(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(dir, { recursive: true, force: true });
  });
  return { dir, root, registry, runtime };
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
  items: [item("c1"), item("c2"), item("c3"), item("c4")],
  seen: ["c1", "c2", "c3", "c4"],
  sent: [],
  progress: { reviewedCount: 5, fileCount: 7 },
  at: "2026-11-03T21:12:12.088148037+00:00",
  ...over,
});

/** A context that names a session, as the review reads it. */
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

  // The review ends: the hub is told there is nothing to wait on.
  reviewLive(env, undefined);
  assert.equal(reviewWaitLabel(env), undefined);
  await until("the cleared dialog line", () => lastOp(hub.lines, "dialog")?.text === null);
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
