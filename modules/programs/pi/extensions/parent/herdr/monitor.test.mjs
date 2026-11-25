import assert from "node:assert/strict";
import { mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { cleanName, renderMonitor, statusOf } from "./monitor.mjs";

const MONITOR = fileURLToPath(new URL("./monitor.mjs", import.meta.url));

// The monitor's own protocol strings: OSC title, herdr status, and clear/home.
const OWN_SEQUENCE = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g;
const UNSAFE = /[\x00-\x08\x0b-\x1f\x7f-\x9f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/;

const bodyOf = (rendered) => rendered.slice(rendered.indexOf("\x1b[H") + 3);
const plainOf = (rendered) => rendered.replace(OWN_SEQUENCE, "");

const startMonitor = (file, parentPid = String(process.pid)) => {
  const child = spawn(process.execPath, [MONITOR, file, parentPid], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const state = { child, output: "", errors: "" };
  child.stdout.on("data", (data) => {
    state.output += data;
  });
  child.stderr.on("data", (data) => {
    state.errors += data;
  });
  return state;
};

const waitFor = async (predicate, label = "output", timeout = 4000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await delay(25);
  }
  throw new Error(`timed out waiting for ${label}`);
};

const occurrences = (text, needle) => text.split(needle).length - 1;

// The same wide-cell estimate the monitor uses, for assertions only.
const WIDE_TEST = /[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7a3]|[\u{1f300}-\u{1faff}]/u;
const cellsOf = (text) => {
  let width = 0;
  for (const char of text) width += WIDE_TEST.test(char) ? 2 : 1;
  return width;
};

/** A snapshot the way the bridge writes it: temp file, then rename. */
const writeSnapshot = async (file, value) => {
  const raw = typeof value === "string" ? value : JSON.stringify(value);
  await writeFile(`${file}.tmp`, raw);
  await rename(`${file}.tmp`, file);
};

test("names cannot inject controls and cleanName stays bounded", () => {
  const hostile = "x\x1b]0;attack\x07\ny\x1b[31m\u202Egnp.exe\u202C\u200B\ufeff\u009b2J\u2066z";
  const cleaned = cleanName(hostile);
  assert.ok(!UNSAFE.test(cleaned), JSON.stringify(cleaned));
  // The OSC payload and every control/bidi character are gone; the plain
  // letters of a reversed name stay, they just cannot reorder anything.
  assert.ok(!cleaned.includes("attack"));
  assert.ok(!cleaned.includes("\u202e") && !cleaned.includes("\u202c"));
  assert.equal(cleanName("x".repeat(300)).length, 160);
  assert.equal(cleanName(undefined), "");
  assert.equal(cleanName(null), "");
  assert.equal(cleanName({}), "");
});

test("lifecycle maps to protocol states and readable explanations", () => {
  assert.equal(statusOf("working"), "working");
  assert.equal(statusOf("waiting"), "idle");
  assert.equal(statusOf("idle"), "done");
  assert.equal(statusOf("failed"), "error");
  assert.equal(statusOf("interrupted"), "idle");
  assert.equal(statusOf("skipped"), "idle");
  assert.equal(statusOf("nonsense"), "idle");
  // Prototype members are not lifecycle states.
  assert.equal(statusOf("constructor"), "idle");
  assert.equal(statusOf("__proto__"), "idle");
  assert.equal(statusOf("toString"), "idle");
  assert.equal(statusOf("hasOwnProperty"), "idle");

  const waiting = renderMonitor({ name: "researcher", state: "waiting" });
  assert.ok(waiting.includes("state=idle:app=pi:"));
  assert.match(waiting, /State: waiting — waiting on its dependencies, not on you/);
  assert.match(renderMonitor({ name: "r", state: "idle" }), /State: idle — completed its turn/);
  assert.match(renderMonitor({ name: "r", state: "failed" }), /State: failed — failed; the error/);
  assert.match(renderMonitor({ name: "r", state: "working" }), /state=working:app=pi:/);
  const simple = renderMonitor({ name: "r", state: "working" });
  assert.ok(simple.includes("Read-only Pi agent monitor"));
  assert.ok(!simple.includes("Recent state changes"));
});

test("a rich snapshot shows identity, cwd, task, model, times and recent history", () => {
  const now = 1_700_000_000_000;
  const rendered = renderMonitor(
    {
      id: "a1",
      name: "researcher",
      state: "waiting",
      cwd: "/home/x/repo",
      parent: "p0",
      sessionId: "session-secret-123456",
      startedAt: now - 185_000,
      updatedAt: now - 12_000,
      task: "Summarize the docs",
      model: "gpt-5",
      history: [
        { state: "working", at: now - 180_000 },
        { state: "idle", at: now - 90_000 },
        { state: "waiting", at: now - 12_000 },
      ],
    },
    { now, columns: 80, rows: 24 },
  );
  assert.match(rendered, /Agent: researcher \(id a1\)/);
  assert.match(rendered, /State: waiting — waiting on its dependencies/);
  assert.match(rendered, /Directory: \/home\/x\/repo/);
  assert.match(rendered, /Task: Summarize the docs/);
  assert.match(rendered, /Model: gpt-5/);
  // startedAt is when the bridge first observed the agent, not when the task
  // began, so the label must not promise a runtime.
  assert.match(rendered, /Observed for: 3m 5s/);
  assert.match(rendered, /Changed: 12s ago/);
  assert.ok(!rendered.includes("Elapsed"));
  assert.ok(!/runtime|running for/i.test(rendered));
  assert.match(rendered, /Recent state changes/);
  assert.match(rendered, /1m 30s ago\s+idle/);
  assert.match(rendered, /12s ago\s+waiting/);
  // The session id is neither shown whole nor used as identity when a name exists.
  assert.ok(!rendered.includes("session-secret-123456"));
  assert.ok(!rendered.includes("p0"));
});

test("a nameless snapshot falls back to its id, then to a short session tail", () => {
  const byId = renderMonitor({ id: "agent-7", state: "working" }, { now: 1000 });
  assert.match(byId, /Agent: agent-7/);
  const bySession = renderMonitor(
    { sessionId: "session-secret-123456", state: "working" },
    { now: 1000 },
  );
  assert.match(bySession, /Agent: agent 123456/);
  assert.ok(!bySession.includes("session-secret-123456"));
  assert.match(renderMonitor({}, { now: 1000 }), /Agent: agent/);
  // Unknown states are shown as unknown, not echoed raw.
  const unknown = renderMonitor({ name: "r", state: "pwn\x1b[2J" }, { now: 1000 });
  assert.match(unknown, /State: unknown — unrecognized state/);
  assert.ok(!plainOf(unknown).includes("pwn"));
  // A state naming a prototype member is unknown too, not a crash or a leak.
  const proto = renderMonitor({ name: "r", state: "__proto__" }, { now: 1000 });
  assert.match(proto, /State: unknown — unrecognized state/);
  assert.ok(proto.includes("state=idle:app=pi:"));
});

test("every untrusted field is sanitized in the body and the title", () => {
  const hostile = "eve\x1b]0;pwned\x07\x1b[31m\x1b[2J\u202Egnp.exe\u202C\n\r\t\u200B\u009b" + "z";
  const rendered = renderMonitor(
    {
      name: hostile,
      state: "working",
      cwd: `/${hostile}/x`,
      task: `task ${hostile}`,
      model: `model ${hostile}`,
      history: [{ state: "idle", at: 900 }],
    },
    { now: 1000, columns: 80, rows: 24 },
  );
  const plain = plainOf(rendered);
  assert.ok(!plain.includes("pwned"));
  assert.ok(!UNSAFE.test(plain), JSON.stringify(plain));
  assert.ok(!plain.includes("\x1b"));
  // The protocol head itself stays intact.
  assert.ok(rendered.includes("\x1b]7501;state=working:app=pi:"));
  assert.ok(rendered.includes("\x1b[2J\x1b[H"));
});

test("long fields and history are bounded to the given viewport", () => {
  const rendered = renderMonitor(
    {
      name: "n".repeat(5000),
      state: "working",
      cwd: `/${"c".repeat(5000)}`,
      task: "t".repeat(5000),
      model: "m".repeat(5000),
      startedAt: 1,
      updatedAt: 1,
      history: Array.from({ length: 500 }, (_, index) => ({ state: "working", at: 900 + index })),
    },
    { now: 1_000_000, columns: 60, rows: 24 },
  );
  const lines = bodyOf(rendered).split("\n");
  // One row is always reserved for the trailing newline.
  assert.ok(lines.length - 1 <= 23, `${lines.length} lines`);
  for (const line of lines) assert.ok(Array.from(line).length <= 60, JSON.stringify(line));
  assert.ok(rendered.endsWith("\n"));
  assert.ok(rendered.length < 5000, `${rendered.length} bytes`);
  // At most eight history rows, however long the history array is.
  const historyRows = lines.filter((line) => /^ {2}.* ago +working *$/.test(line));
  assert.equal(historyRows.length, 8);

  // Wide code points count two cells, so a CJK or emoji name cannot overrun.
  const wide = renderMonitor(
    { name: "実".repeat(200), state: "working", task: "😀".repeat(200) },
    { now: 1_000_000, columns: 40, rows: 20 },
  );
  const wideLines = bodyOf(wide).split("\n");
  assert.ok(wideLines.length - 1 <= 19);
  for (const line of wideLines) assert.ok(cellsOf(line) <= 40, JSON.stringify(line));

  // A tiny terminal still gets a bounded frame rather than a scrolling dump.
  const tiny = renderMonitor({ name: "r".repeat(400), state: "working" }, { columns: 20, rows: 6 });
  const tinyLines = bodyOf(tiny).split("\n");
  assert.ok(tinyLines.length - 1 <= 5);
  for (const line of tinyLines) assert.ok(Array.from(line).length <= 20);
  // Absurd viewports are clamped, not trusted.
  const clamped = renderMonitor({ name: "r", state: "idle" }, { columns: -5, rows: -5 });
  assert.ok(bodyOf(clamped).split("\n").length - 1 <= 23);
});

test("a full-height frame reserves the last viewport row", () => {
  const now = 1_700_000_000_000;
  const rendered = renderMonitor(
    {
      name: "researcher",
      state: "working",
      cwd: "/repo",
      startedAt: now - 5000,
      updatedAt: now - 2000,
      history: Array.from({ length: 8 }, (_, index) => ({
        state: "working",
        at: now - (index + 1) * 1000,
      })),
    },
    { now, columns: 80, rows: 10 },
  );
  const lines = bodyOf(rendered).split("\n");
  assert.ok(lines.length - 1 <= 9, `${lines.length} lines`);
  assert.ok(rendered.endsWith("\n"));

  const tall = renderMonitor({ name: "researcher", state: "working" }, { columns: 80, rows: 24 });
  assert.ok(bodyOf(tall).split("\n").length - 1 <= 23);
});

test("constrained history keeps its newest tail", () => {
  const now = 1_700_000_000_000;
  const history = Array.from({ length: 8 }, (_, index) => ({
    state: ["working", "waiting", "idle"][index % 3],
    at: now - (8 - index) * 1000,
  }));
  // rows 12 leaves room for the heading and exactly two events.
  const rendered = renderMonitor(
    { name: "researcher", state: "working", history },
    {
      now,
      columns: 80,
      rows: 12,
    },
  );
  assert.match(rendered, /Recent state changes/);
  assert.match(rendered, /1s ago\s+waiting/);
  assert.match(rendered, /2s ago\s+working/);
  assert.ok(!rendered.includes("7s ago"), "oldest entry leaked into a short frame");
  assert.ok(!rendered.includes("8s ago"), "oldest entry leaked into a short frame");
  assert.ok(bodyOf(rendered).split("\n").length - 1 <= 11);
});

test(
  "clock ticks redraw the body without repeating the protocol status",
  { timeout: 10_000 },
  async () => {
    const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
    const file = join(dir, "state.json");
    const now = Date.now();
    // Unchanged content, as the bridge writes nothing when the state is stable.
    await writeSnapshot(file, {
      id: "a1",
      name: "researcher",
      state: "working",
      startedAt: now - 5_000,
      updatedAt: now - 2_000,
    });
    const monitor = startMonitor(file);
    try {
      await waitFor(() => monitor.output.includes("Observed for"), "first frame");
      const firstFrames = occurrences(monitor.output, "Observed for");
      assert.equal(occurrences(monitor.output, "\x1b]7501;state="), 1);
      assert.equal(occurrences(monitor.output, "\x1b[2J"), 1);

      await waitFor(
        () => occurrences(monitor.output, "Observed for") > firstFrames,
        "clock redraw",
        4000,
      );
      // The screen moved on, but herdr saw the status exactly once: no OSC
      // churn on a clock tick, just a home-positioned body redraw.
      assert.equal(occurrences(monitor.output, "\x1b]7501;state="), 1);
      assert.equal(occurrences(monitor.output, "\x1b[2J"), 1);
      assert.ok(occurrences(monitor.output, "\x1b[H") > 1);

      await rm(file);
      const [code] = await once(monitor.child, "exit");
      assert.equal(code, 0);
      assert.equal(monitor.errors, "");
      assert.ok(monitor.output.includes("state=clear"));
    } finally {
      monitor.child.kill("SIGKILL");
      await rm(dir, { recursive: true, force: true });
    }
  },
);

test(
  "malformed snapshots render once, then recover without spam",
  { timeout: 10_000 },
  async () => {
    const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
    const file = join(dir, "state.json");
    await writeSnapshot(file, "{ not json");
    const monitor = startMonitor(file);
    try {
      await waitFor(() => monitor.output.includes("Unreadable agent state"), "malformed screen");
      await delay(800);
      assert.equal(occurrences(monitor.output, "Unreadable agent state"), 1);
      assert.ok(!monitor.output.includes("not json"));

      await writeSnapshot(file, { name: "researcher", state: "working" });
      await waitFor(() => monitor.output.includes("State: working"), "recovered snapshot");
      await rm(file);
      const [code] = await once(monitor.child, "exit");
      assert.equal(code, 0);
      assert.equal(monitor.errors, "");
      assert.ok(monitor.output.includes("state=clear"));
    } finally {
      monitor.child.kill("SIGKILL");
      await rm(dir, { recursive: true, force: true });
    }
  },
);

test(
  "oversized files are rejected without echoing their contents",
  { timeout: 10_000 },
  async () => {
    const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
    const file = join(dir, "state.json");
    await writeSnapshot(file, "x".repeat(200_000));
    const monitor = startMonitor(file);
    try {
      await waitFor(() => monitor.output.includes("Unreadable agent state"), "oversized screen");
      await delay(500);
      assert.ok(!monitor.output.includes("xxxxxxxxxx"));
      assert.ok(monitor.output.length < 4096, `${monitor.output.length} bytes`);
      await rm(file);
      const [code] = await once(monitor.child, "exit");
      assert.equal(code, 0);
      assert.ok(monitor.output.includes("state=clear"));
    } finally {
      monitor.child.kill("SIGKILL");
      await rm(dir, { recursive: true, force: true });
    }
  },
);

test("a missing state file exits cleanly with the status cleared", { timeout: 5000 }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
  const monitor = startMonitor(join(dir, "absent.json"));
  try {
    const [code] = await once(monitor.child, "exit");
    assert.equal(code, 0);
    assert.equal(monitor.errors, "");
    assert.ok(monitor.output.includes("state=clear"));
  } finally {
    monitor.child.kill("SIGKILL");
    await rm(dir, { recursive: true, force: true });
  }
});

test("a dead parent ends the monitor and clears the status", { timeout: 10_000 }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
  const file = join(dir, "state.json");
  await writeSnapshot(file, { name: "researcher", state: "working" });
  const parent = spawn(process.execPath, ["-e", "setTimeout(() => {}, 400)"], {
    stdio: "ignore",
  });
  const monitor = startMonitor(file, String(parent.pid));
  try {
    await waitFor(() => monitor.output.includes("State: working"), "first snapshot");
    await once(parent, "exit");
    const [code] = await once(monitor.child, "exit");
    assert.equal(code, 0);
    assert.equal(monitor.errors, "");
    assert.ok(monitor.output.includes("state=clear"));
  } finally {
    parent.kill("SIGKILL");
    monitor.child.kill("SIGKILL");
    await rm(dir, { recursive: true, force: true });
  }
});

test("a signal from herdr exits zero and clears the status", { timeout: 5000 }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
  const file = join(dir, "state.json");
  await writeSnapshot(file, { name: "researcher", state: "working" });
  const monitor = startMonitor(file);
  try {
    await waitFor(() => monitor.output.includes("State: working"), "first snapshot");
    monitor.child.kill("SIGTERM");
    const [code, signal] = await once(monitor.child, "exit");
    assert.equal(signal, null);
    assert.equal(code, 0);
    assert.ok(monitor.output.includes("state=clear"));
  } finally {
    monitor.child.kill("SIGKILL");
    await rm(dir, { recursive: true, force: true });
  }
});
