// Regression tests for the pi-agents lifecycle tracer added by
// ../pi-telemetry-phoenix.patch. They load the exact module the patch
// installs and assert deterministic span events, including that snapshots
// from another session, publisher instance, or a restarted session never
// attach to this session's runs.
//
// Run with: node --test pkgs/pi-packages/tests/agent-lifecycle.test.mjs
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const patchPath =
  process.env.PI_TELEMETRY_PATCH ??
  fileURLToPath(new URL("../pi-telemetry-phoenix.patch", import.meta.url));
const patch = await readFile(patchPath, "utf8");

/** Extract the body of a new-file hunk from the unified patch. */
function extractNewFile(source, target) {
  const lines = source.split(/\r?\n/);
  const start = lines.findIndex(
    (line, index) => line === `+++ b/${target}` && lines[index - 1] === "--- /dev/null",
  );
  assert.notEqual(start, -1, `patch does not create ${target}`);
  const header = lines[start + 1];
  const match = /^@@ -0,0 \+1,(\d+) @@/.exec(header);
  assert.ok(match, `unexpected hunk header for ${target}: ${header}`);
  const count = Number(match[1]);
  const body = lines.slice(start + 2, start + 2 + count);
  assert.equal(body.length, count, `truncated hunk for ${target}`);
  assert.ok(
    body.every((line) => line.startsWith("+")),
    `non-addition in new-file hunk for ${target}`,
  );
  return `${body.map((line) => line.slice(1)).join("\n")}\n`;
}

const tracerSource = extractNewFile(patch, "dist/agent-lifecycle.js");

// Nix runs this against the package it just patched. Without that env var the
// test extracts the new file from the patch, so local edits still test.
let AgentLifecycleTracer;
const installedDir = process.env.PI_TELEMETRY_DIR;
if (installedDir) {
  const installedSource = await readFile(join(installedDir, "dist", "agent-lifecycle.js"), "utf8");
  assert.equal(
    installedSource,
    tracerSource,
    "the built telemetry package does not match the patch",
  );
  const extensionSource = await readFile(join(installedDir, "dist", "extension.js"), "utf8");
  assert.match(extensionSource, /from '\.\/agent-lifecycle\.js'/);
  assert.match(extensionSource, /AgentLifecycleTracer/);
  assert.match(extensionSource, /publisherSessionId: localSessionId/);
  assert.match(extensionSource, /agentTracer\.close\('session_shutdown'\)/);
  const exportersSource = await readFile(
    join(installedDir, "dist", "otel", "exporters.js"),
    "utf8",
  );
  assert.match(
    exportersSource,
    /lifecycleSource !== 'pi-agents:state'/,
    "lifecycle-only child spans must not clobber the launch traceparent",
  );
  assert.doesNotMatch(extensionSource, /in-process-subagents|subagents:child:session-created/);
  ({ AgentLifecycleTracer } = await import(
    pathToFileURL(join(installedDir, "dist", "agent-lifecycle.js")).href
  ));
} else {
  const moduleDir = await mkdtemp(join(tmpdir(), "pi-agent-lifecycle-"));
  await writeFile(join(moduleDir, "agent-lifecycle.mjs"), tracerSource);
  ({ AgentLifecycleTracer } = await import(
    pathToFileURL(join(moduleDir, "agent-lifecycle.mjs")).href
  ));
}

const SESSION = "session-main";
const OTHER_SESSION = "session-other";
const TRACE = "a".repeat(32);
const OTHER_TRACE = "b".repeat(32);

function snapshot({
  sessionId = SESSION,
  instanceId = "publisher-1",
  sequence = 1,
  type = "snapshot",
  agents = [],
} = {}) {
  return { protocol: 1, sessionId, instanceId, sequence, type, agents };
}

function agent(id, name, state, closed = false) {
  return { id, name, state, closed };
}

function harness({ sessionId = SESSION, traceId = TRACE } = {}) {
  const events = [];
  const errors = [];
  let clock = 1_000;
  const tracer = new AgentLifecycleTracer({
    publish: (event) => {
      events.push(event);
    },
    sessionId,
    traceId,
    now: () => {
      clock += 10;
      return clock;
    },
    log: (error) => {
      errors.push(error);
    },
  });
  return { tracer, events, errors, advance: (ms) => (clock += ms) };
}

function fakeBus() {
  const listeners = new Map();
  const emitted = [];
  return {
    emitted,
    on(channel, handler) {
      const handlers = listeners.get(channel) ?? new Set();
      handlers.add(handler);
      listeners.set(channel, handlers);
      return () => handlers.delete(handler);
    },
    emit(channel, value) {
      emitted.push({ channel, value });
      for (const handler of listeners.get(channel) ?? []) handler(value);
    },
    count(channel) {
      return listeners.get(channel)?.size ?? 0;
    },
  };
}

test("patch wires the lifecycle tracer and drops the old in-process registry", () => {
  assert.match(tracerSource, /pi-agents:state/);
  assert.match(tracerSource, /pi-agents:state:request/);
  assert.match(tracerSource, /subagent_started/);
  assert.match(tracerSource, /publisherSessionId/);

  const added = patch
    .split(/\r?\n/)
    .filter((line) => line.startsWith("+") && !line.startsWith("+++"))
    .join("\n");
  assert.match(added, /AgentLifecycleTracer/);
  assert.match(added, /publisherSessionId: localSessionId/);
  assert.match(added, /agentTracer\.close\('session_shutdown'\)/);
  assert.match(added, /lifecycleSource !== 'pi-agents:state'/);
  assert.doesNotMatch(added, /in-process-subagents/);
  assert.doesNotMatch(added, /subagents:child:session-created/);
  assert.doesNotMatch(added, /agentNameFromPrompt/);
  assert.doesNotMatch(added, /PI_SUBAGENT_CHILD_AGENT/);
});

test("one span per agent run, with stable id and name", async () => {
  const { tracer, events } = harness();
  const scout = agent("agent-1", "scout", "working");
  const writer = agent("agent-2", "writer", "waiting");

  tracer.handle(snapshot({ sequence: 1, agents: [scout, writer] }));
  await tracer.flush();

  assert.deepEqual(
    events.map((event) => [event.type, event.childSessionId]),
    [
      ["subagent_started", "agent-1"],
      ["subagent_started", "agent-2"],
    ],
  );
  for (const event of events) {
    assert.equal(event.sessionId, SESSION);
    assert.equal(event.parentSessionId, SESSION);
    assert.equal(event.traceId, TRACE);
    assert.match(event.id, /^[0-9a-f-]{36}$/);
    assert.match(event.runId, /^[0-9a-f-]{36}$/);
  }
  assert.equal(events[0].details.agent, "scout");
  assert.equal(events[0].details.agentId, "agent-1");
  assert.equal(events[0].details.lifecycleSource, "pi-agents:state");
  assert.equal(events[1].details.agent, "writer");
  assert.notEqual(events[0].runId, events[1].runId);

  // A repeated snapshot is not a new start.
  tracer.handle(snapshot({ sequence: 2, agents: [scout, writer] }));
  await tracer.flush();
  assert.equal(events.length, 2);

  // idle completes; a name change on a live run stays with its identity.
  tracer.handle(
    snapshot({
      sequence: 3,
      agents: [agent("agent-1", "scout-renamed", "idle"), writer],
    }),
  );
  await tracer.flush();
  assert.equal(events.length, 3);
  assert.equal(events[2].type, "subagent_completed");
  assert.equal(events[2].childSessionId, "agent-1");
  assert.equal(events[2].details.agent, "scout");
  assert.equal(events[2].details.outcome, "completed");
  assert.equal(events[2].details.lifecycleSource, "pi-agents:state");
  assert.equal(events[2].runId, events[0].runId);
  assert.ok(events[2].durationMs >= 0);

  tracer.handle(
    snapshot({
      sequence: 4,
      agents: [agent("agent-2", "writer", "interrupted")],
    }),
  );
  await tracer.flush();
  assert.equal(events.length, 4);
  assert.equal(events[3].type, "subagent_cancelled");
  assert.equal(events[3].childSessionId, "agent-2");
  assert.equal(events[3].details.outcome, "interrupted");
  assert.equal(events[3].runId, events[1].runId);
});

test("maps completion, failure, interruption, skip, and unobserved close", async () => {
  const { tracer, events } = harness();
  const agents = [
    agent("done", "done", "working"),
    agent("failed", "failed", "working"),
    agent("interrupted", "interrupted", "working"),
    agent("skipped", "skipped", "working"),
    agent("hidden", "hidden", "working"),
  ];
  tracer.handle(snapshot({ sequence: 1, agents }));
  await tracer.flush();
  assert.equal(events.length, 5);

  tracer.handle(
    snapshot({
      sequence: 2,
      agents: [
        agent("done", "done", "idle"),
        agent("failed", "failed", "failed"),
        agent("interrupted", "interrupted", "interrupted"),
        agent("skipped", "skipped", "skipped"),
        // hidden is a closed agent that no longer works: it leaves the snapshot.
      ],
    }),
  );
  await tracer.flush();

  const terminal = events.slice(5);
  assert.deepEqual(
    terminal.map((event) => [event.childSessionId, event.type, event.details.outcome]),
    [
      ["done", "subagent_completed", "completed"],
      ["failed", "subagent_failed", "failed"],
      ["interrupted", "subagent_cancelled", "interrupted"],
      ["skipped", "subagent_cancelled", "skipped"],
      // A hidden closed agent is not evidence of success: it may have
      // failed or been interrupted between snapshots.
      ["hidden", "subagent_completed", "closed"],
    ],
  );
  const failure = terminal.find((event) => event.childSessionId === "failed");
  assert.equal(failure.error, "Agent failed");
  // The failure is classified, never quoted from the agent's conversation.
  assert.ok(!Object.values(failure.details).includes("Agent failed"));
});

test("waits for the main trace instead of emitting a detached one", async () => {
  const { tracer, events } = harness({ traceId: null });
  const scout = agent("agent-1", "scout", "working");

  tracer.handle(snapshot({ sequence: 1, agents: [scout] }));
  await tracer.flush();
  assert.equal(events.length, 0);

  tracer.setTraceId(TRACE);
  await tracer.flush();
  assert.equal(events.length, 1);
  assert.equal(events[0].traceId, TRACE);
  assert.equal(events[0].details.restored, true);

  // A new agent whose whole life happens outside a chat turn is not recorded.
  tracer.setTraceId(undefined);
  tracer.handle(
    snapshot({
      sequence: 2,
      agents: [scout, agent("agent-2", "brief", "working")],
    }),
  );
  await tracer.flush();
  assert.equal(events.length, 1);
  tracer.handle(
    snapshot({
      sequence: 3,
      agents: [scout, agent("agent-2", "brief", "idle")],
    }),
  );
  tracer.setTraceId(TRACE);
  await tracer.flush();
  assert.equal(events.length, 1);

  // The completed run keeps the trace it started in.
  tracer.handle(snapshot({ sequence: 4, agents: [agent("agent-1", "scout", "idle")] }));
  await tracer.flush();
  assert.equal(events.at(-1).type, "subagent_completed");
  assert.equal(events.at(-1).traceId, TRACE);
});

test("ignores snapshots from another session", async () => {
  const first = harness();
  const second = harness({ sessionId: OTHER_SESSION, traceId: OTHER_TRACE });

  first.tracer.handle(
    snapshot({ sessionId: OTHER_SESSION, agents: [agent("theirs", "theirs", "working")] }),
  );
  first.tracer.handle(snapshot({ agents: [agent("mine", "mine", "working")] }));
  await first.tracer.flush();
  assert.deepEqual(
    first.events.map((event) => [event.childSessionId, event.sessionId]),
    [["mine", SESSION]],
  );

  second.tracer.handle(snapshot({ sessionId: SESSION, agents: [agent("mine", "mine", "idle")] }));
  second.tracer.handle(
    snapshot({
      sessionId: OTHER_SESSION,
      instanceId: "publisher-2",
      agents: [agent("theirs", "theirs", "working")],
    }),
  );
  await second.tracer.flush();
  assert.deepEqual(
    second.events.map((event) => event.childSessionId),
    ["theirs"],
  );
  assert.equal(second.events[0].traceId, OTHER_TRACE);

  await first.tracer.close();
  assert.equal(second.events.length, 1, "closing one session leaves the other alone");
});

test("a nested pi process keeps the root trace lineage", async () => {
  const rootSession = "root-session";
  const nestedSession = "nested-process-session";
  const events = [];
  const tracer = new AgentLifecycleTracer({
    publish: (event) => {
      events.push(event);
    },
    sessionId: rootSession,
    publisherSessionId: nestedSession,
    traceId: TRACE,
    now: () => 1_000,
  });

  // The root session's publisher shares the bus but is not this tracer's.
  tracer.handle(
    snapshot({ sessionId: rootSession, agents: [agent("root-agent", "root", "working")] }),
  );
  tracer.handle(
    snapshot({
      sessionId: nestedSession,
      agents: [agent("nested-agent", "nested", "working")],
    }),
  );
  await tracer.flush();
  assert.deepEqual(
    events.map((event) => [
      event.childSessionId,
      event.sessionId,
      event.parentSessionId,
      event.traceId,
    ]),
    [["nested-agent", rootSession, rootSession, TRACE]],
  );
});

test("a stopped or replaced publisher cannot leak old runs", async () => {
  const { tracer, events } = harness();
  tracer.handle(
    snapshot({ instanceId: "publisher-1", agents: [agent("agent-1", "scout", "working")] }),
  );
  await tracer.flush();
  const firstRun = events[0].runId;

  tracer.handle(snapshot({ instanceId: "publisher-1", sequence: 2, type: "stopped", agents: [] }));
  await tracer.flush();
  assert.equal(events[1].type, "subagent_cancelled");
  assert.equal(events[1].details.outcome, "publisher_stopped");
  assert.equal(events[1].runId, firstRun);

  // A late snapshot of the stopped instance must not resurrect the run.
  tracer.handle(
    snapshot({
      instanceId: "publisher-1",
      sequence: 3,
      agents: [agent("agent-1", "scout", "working")],
    }),
  );
  await tracer.flush();
  assert.equal(events.length, 2);

  // A new publisher starts a fresh run with the same stable agent identity.
  tracer.handle(
    snapshot({
      instanceId: "publisher-2",
      sequence: 1,
      agents: [agent("agent-1", "scout", "working")],
    }),
  );
  await tracer.flush();
  assert.equal(events.length, 3);
  assert.equal(events[2].type, "subagent_started");
  assert.equal(events[2].childSessionId, "agent-1");
  assert.equal(events[2].details.agent, "scout");
  assert.notEqual(events[2].runId, firstRun);

  // Replacing the publisher without a stopped event closes its orphans first.
  tracer.handle(
    snapshot({
      instanceId: "publisher-3",
      sequence: 1,
      agents: [agent("agent-1", "scout", "waiting")],
    }),
  );
  await tracer.flush();
  assert.deepEqual(
    events.slice(3).map((event) => [event.type, event.details.outcome]),
    [
      ["subagent_cancelled", "publisher_replaced"],
      ["subagent_started", undefined],
    ],
  );
  assert.equal(events[3].runId, events[2].runId);
});

test("ignores out-of-order snapshots within one publisher", async () => {
  const { tracer, events } = harness();
  const scout = agent("agent-1", "scout", "working");
  tracer.handle(snapshot({ sequence: 5, agents: [scout] }));
  tracer.handle(snapshot({ sequence: 4, agents: [agent("agent-1", "scout", "idle")] }));
  await tracer.flush();
  assert.deepEqual(
    events.map((event) => event.type),
    ["subagent_started"],
  );

  tracer.handle(snapshot({ sequence: 6, agents: [agent("agent-1", "scout", "idle")] }));
  await tracer.flush();
  assert.deepEqual(
    events.map((event) => event.type),
    ["subagent_started", "subagent_completed"],
  );
});

test("reworking a completed agent opens a new run, not a duplicate id", async () => {
  const { tracer, events } = harness();
  const scout = agent("agent-1", "scout", "working");
  tracer.handle(snapshot({ sequence: 1, agents: [scout] }));
  tracer.handle(snapshot({ sequence: 2, agents: [agent("agent-1", "scout", "idle")] }));
  tracer.handle(snapshot({ sequence: 3, agents: [scout] }));
  await tracer.flush();

  assert.deepEqual(
    events.map((event) => [event.type, event.childSessionId]),
    [
      ["subagent_started", "agent-1"],
      ["subagent_completed", "agent-1"],
      ["subagent_started", "agent-1"],
    ],
  );
  assert.notEqual(events[0].runId, events[2].runId);
  assert.equal(events[2].details.agent, "scout");
  assert.ok(!("restored" in events[2].details));
});

test("shutdown closes open runs and is idempotent", async () => {
  const { tracer, events, errors } = harness();
  tracer.handle(
    snapshot({
      sequence: 1,
      agents: [agent("agent-1", "scout", "working"), agent("agent-2", "writer", "waiting")],
    }),
  );
  tracer.flush();
  await tracer.close("session_shutdown");
  assert.deepEqual(
    events.slice(2).map((event) => [event.type, event.childSessionId, event.details.outcome]),
    [
      ["subagent_cancelled", "agent-1", "session_shutdown"],
      ["subagent_cancelled", "agent-2", "session_shutdown"],
    ],
  );

  await tracer.close("session_shutdown");
  tracer.handle(snapshot({ sequence: 2, agents: [agent("agent-3", "late", "working")] }));
  await tracer.flush();
  assert.equal(events.length, 4);
  tracer.dispose();
  assert.deepEqual(errors, []);
});

test("subscribe requests the current snapshot and unsubscribes", async () => {
  const { tracer, events } = harness();
  const bus = fakeBus();
  const unsubscribe = tracer.subscribe(bus);
  assert.equal(bus.count("pi-agents:state"), 1);
  assert.deepEqual(bus.emitted[0], {
    channel: "pi-agents:state:request",
    value: { protocol: 1 },
  });

  bus.emit("pi-agents:state", snapshot({ agents: [agent("agent-1", "scout", "working")] }));
  await tracer.flush();
  assert.equal(events.length, 1);

  unsubscribe();
  assert.equal(bus.count("pi-agents:state"), 0);
  bus.emit(
    "pi-agents:state",
    snapshot({ sequence: 2, agents: [agent("agent-1", "scout", "idle")] }),
  );
  await tracer.flush();
  assert.equal(events.length, 1);
  await tracer.close();
});

test("malformed snapshots and agents are ignored without throwing", async () => {
  const { tracer, events, errors } = harness();
  for (const value of [
    undefined,
    null,
    42,
    {},
    snapshot({ protocol: 2 }),
    snapshot({ agents: "not-an-array" }),
    snapshot({ sequence: 2, agents: [null, {}, { id: "", name: "x", state: "working" }] }),
    snapshot({
      sequence: 3,
      agents: [agent("dup", "first", "working"), agent("dup", "second", "working")],
    }),
  ]) {
    tracer.handle(value);
  }
  await tracer.flush();
  assert.deepEqual(
    events.map((event) => [event.childSessionId, event.details.agent]),
    [["dup", "first"]],
  );
  assert.deepEqual(errors, []);
});
