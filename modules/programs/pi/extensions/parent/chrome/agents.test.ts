import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AGENTS_STATE_EVENT,
  AGENTS_STATE_REQUEST_EVENT,
  agentParts,
  createAgentState,
  createAgentTracker,
  parseSnapshot,
} from "./agents.ts";
import type { AgentLifecycle, AgentsSnapshot } from "./agents.ts";
import type { Action } from "./state.ts";

type LifecycleState = AgentLifecycle["state"];

const agent = (id: string, state: LifecycleState, closed = false): AgentLifecycle => ({
  id,
  name: id,
  state,
  closed,
});

type SnapshotOptions = {
  type?: AgentsSnapshot["type"];
  sessionId?: string;
  instanceId?: string;
  sequence?: number;
  agents?: readonly AgentLifecycle[];
};

const snapshot = ({
  type = "snapshot",
  sessionId = "session-1",
  instanceId = "instance-1",
  sequence = 1,
  agents = [],
}: SnapshotOptions = {}): AgentsSnapshot => ({
  protocol: 1,
  sessionId,
  instanceId,
  sequence,
  type,
  agents,
});

const noop = (() => {}) as Action;

/** The slice of pi.events the footer uses, plus what the test emitted. */
const createBus = () => {
  const handlers = new Map<string, Set<(data: unknown) => void>>();
  const emitted: Array<{ channel: string; data: unknown }> = [];
  return {
    emitted,
    on(channel: string, handler: (data: unknown) => void) {
      const set = handlers.get(channel) ?? new Set();
      handlers.set(channel, set);
      set.add(handler);
      return () => set.delete(handler);
    },
    emit(channel: string, data: unknown) {
      emitted.push({ channel, data });
      for (const handler of [...(handlers.get(channel) ?? [])]) handler(data);
    },
  };
};

test("empty session: no counts and no segment", () => {
  const tracker = createAgentTracker();
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 0 });
  assert.deepEqual(agentParts(tracker.counts(), noop), []);
});

test("running agents: one clickable segment counting only working agents", () => {
  const tracker = createAgentTracker();
  assert.equal(
    tracker.accept(
      snapshot({
        agents: [
          agent("a", "working"),
          agent("b", "working"),
          agent("c", "idle"),
          agent("d", "failed"),
        ],
      }),
    ),
    true,
  );
  assert.deepEqual(tracker.counts(), { working: 2, waiting: 0 });
  const parts = agentParts(tracker.counts(), noop);
  assert.equal(parts.length, 1);
  assert.equal(parts[0]?.id, "agents");
  assert.equal(parts[0]?.action, noop);
  assert.match(parts[0]?.text ?? "", / 2$/);
});

test("waiting agents: dependency waits count beside running ones, never as queued", () => {
  const tracker = createAgentTracker();
  assert.equal(
    tracker.accept(
      snapshot({
        agents: [agent("a", "working"), agent("b", "waiting"), agent("c", "waiting")],
      }),
    ),
    true,
  );
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 2 });
  assert.match(agentParts(tracker.counts(), noop)[0]?.text ?? "", / 1 \+2$/);

  assert.equal(tracker.accept(snapshot({ sequence: 2, agents: [agent("a", "waiting")] })), true);
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 1 });
  assert.match(agentParts(tracker.counts(), noop)[0]?.text ?? "", / 0 \+1$/);
});

test("closed agents: closed non-working ones drop out, closed working ones still count", () => {
  const tracker = createAgentTracker();
  assert.equal(
    tracker.accept(
      snapshot({
        agents: [
          agent("a", "working", true),
          agent("b", "waiting", true),
          agent("c", "idle", true),
          agent("d", "failed", true),
        ],
      }),
    ),
    true,
  );
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 0 });
  assert.match(agentParts(tracker.counts(), noop)[0]?.text ?? "", / 1$/);
});

test("malformed snapshots are ignored whole, including legacy queued states", () => {
  const tracker = createAgentTracker();
  tracker.accept(snapshot({ agents: [agent("a", "working")] }));
  const cases: unknown[] = [
    null,
    "snapshot",
    { ...snapshot(), protocol: 2 },
    { ...snapshot({ sequence: 2 }), agents: "not an array" },
    snapshot({
      sequence: 2,
      agents: [{ id: "a", name: "a", state: "queued", closed: false }] as never,
    }),
    snapshot({ sequence: 2, agents: [{ id: "a", name: "a", state: "idle" }] as never }),
    snapshot({ sequence: 0 }),
    snapshot({ sequence: 1.5 }),
    { ...snapshot({ sequence: 2 }), sequence: "2" },
    snapshot({ sequence: 2, instanceId: "" }),
    snapshot({ sequence: 2, sessionId: "" }),
    { ...snapshot({ sequence: 2 }), type: "replaced" },
  ];
  for (const value of cases) assert.equal(tracker.accept(value), false);
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 0 });
  assert.equal(parseSnapshot(cases[4]), undefined);
});

test("snapshots replace state; duplicates and stale sequences are ignored", () => {
  const tracker = createAgentTracker();
  assert.equal(tracker.accept(snapshot({ sequence: 1, agents: [agent("a", "working")] })), true);
  assert.equal(
    tracker.accept(snapshot({ sequence: 3, agents: [agent("a", "idle"), agent("b", "working")] })),
    true,
  );
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 0 });

  assert.equal(
    tracker.accept(
      snapshot({ sequence: 2, agents: [agent("a", "working"), agent("b", "working")] }),
    ),
    false,
  );
  assert.equal(tracker.accept(snapshot({ sequence: 3, agents: [agent("a", "waiting")] })), false);
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 0 });
});

test("a new publisher instance starts its own sequence again", () => {
  const tracker = createAgentTracker();
  tracker.accept(snapshot({ instanceId: "first", sequence: 7, agents: [agent("a", "working")] }));
  assert.equal(
    tracker.accept(
      snapshot({ instanceId: "second", sequence: 1, agents: [agent("b", "waiting")] }),
    ),
    true,
  );
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 1 });
});

test("a replaced session neither receives nor resurrects another session's counts", () => {
  let current = "session-1";
  const tracker = createAgentTracker(() => current);
  assert.equal(
    tracker.accept(
      snapshot({ sessionId: "session-1", sequence: 1, agents: [agent("a", "working")] }),
    ),
    true,
  );
  current = "session-2";
  assert.equal(
    tracker.accept(
      snapshot({
        sessionId: "session-1",
        instanceId: "old",
        sequence: 2,
        agents: [agent("b", "waiting")],
      }),
    ),
    false,
  );
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 0 });
  assert.equal(
    tracker.accept(
      snapshot({
        sessionId: "session-2",
        instanceId: "new",
        sequence: 1,
        agents: [agent("c", "waiting")],
      }),
    ),
    true,
  );
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 1 });
});

test("stopped clears ownership without claiming the durable work finished", () => {
  const tracker = createAgentTracker();
  tracker.accept(snapshot({ sequence: 1, agents: [agent("a", "working"), agent("b", "waiting")] }));
  assert.equal(tracker.accept(snapshot({ sequence: 2, type: "stopped" })), true);
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 0 });
  assert.deepEqual(agentParts(tracker.counts(), noop), []);

  // A late snapshot of the stopped instance cannot bring the counts back.
  assert.equal(tracker.accept(snapshot({ sequence: 2, agents: [agent("a", "working")] })), false);
  assert.equal(tracker.accept(snapshot({ sequence: 3, agents: [agent("c", "working")] })), true);
  assert.deepEqual(tracker.counts(), { working: 1, waiting: 0 });
});

test("reset forgets the publisher and its sequence", () => {
  const tracker = createAgentTracker();
  tracker.accept(snapshot({ sequence: 5, agents: [agent("a", "working")] }));
  tracker.reset();
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 0 });
  assert.equal(tracker.accept(snapshot({ sequence: 1, agents: [agent("a", "waiting")] })), true);
  assert.deepEqual(tracker.counts(), { working: 0, waiting: 1 });
});

test("wiring requests a snapshot and repaints only when one is accepted", () => {
  const bus = createBus();
  let published = snapshot({ sequence: 1, agents: [agent("a", "working")] });
  bus.on(AGENTS_STATE_REQUEST_EVENT, (request) => {
    assert.deepEqual(request, { protocol: 1 });
    bus.emit(AGENTS_STATE_EVENT, published);
  });
  let repaints = 0;
  const source = createAgentState(
    bus,
    () => repaints++,
    () => "session-1",
  );

  assert.equal(repaints, 1);
  assert.deepEqual(source.tracker.counts(), { working: 1, waiting: 0 });

  bus.emit(AGENTS_STATE_EVENT, published);
  assert.equal(repaints, 1);

  published = snapshot({ sequence: 2, agents: [agent("a", "waiting")] });
  bus.emit(AGENTS_STATE_EVENT, published);
  assert.equal(repaints, 2);
  assert.deepEqual(source.tracker.counts(), { working: 0, waiting: 1 });

  published = snapshot({ sequence: 3, type: "stopped" });
  bus.emit(AGENTS_STATE_EVENT, published);
  assert.equal(repaints, 3);
  assert.deepEqual(source.tracker.counts(), { working: 0, waiting: 0 });

  source.dispose();
  published = snapshot({ sequence: 4, agents: [agent("a", "working")] });
  bus.emit(AGENTS_STATE_EVENT, published);
  assert.equal(repaints, 3);
});

test("wiring follows a session replacement through a fresh request", () => {
  const bus = createBus();
  let current = "session-1";
  let published = snapshot({
    sessionId: "session-1",
    instanceId: "instance-1",
    sequence: 4,
    agents: [agent("a", "working")],
  });
  bus.on(AGENTS_STATE_REQUEST_EVENT, () => bus.emit(AGENTS_STATE_EVENT, published));
  let repaints = 0;
  const source = createAgentState(
    bus,
    () => repaints++,
    () => current,
  );
  assert.equal(repaints, 1);

  current = "session-2";
  // The old publisher still answers until the replacement publishes its own.
  source.request();
  assert.equal(repaints, 1);
  published = snapshot({
    sessionId: "session-2",
    instanceId: "instance-2",
    sequence: 1,
    agents: [agent("b", "waiting")],
  });
  source.request();
  assert.equal(repaints, 2);
  assert.deepEqual(source.tracker.counts(), { working: 0, waiting: 1 });
});
