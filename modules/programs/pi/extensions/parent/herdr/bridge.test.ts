import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createHerdrBridge } from "./bridge.ts";

const snapshot = (sequence: number, agents: unknown[], extra = {}) => ({
  protocol: 1,
  sessionId: "session",
  instanceId: "instance",
  sequence,
  type: "snapshot",
  agents,
  ...extra,
});
const agent = (state = "working", closed = false) => ({
  id: "agent",
  name: "researcher",
  state,
  closed,
});

async function fixture() {
  const calls: string[][] = [];
  const errors: unknown[] = [];
  let count = 0;
  const bridge = await createHerdrBridge({
    parent: "t6",
    sessionId: "session",
    cwd: "/repo",
    monitor: "/monitor.mjs",
    run: async (args) => {
      calls.push(args);
      return JSON.stringify({ address: `t${++count}` });
    },
    onError: (error) => errors.push(error),
  });
  return { bridge, calls, errors };
}

test("one read-only terminal per agent; status updates never restart inference", async () => {
  const { bridge, calls, errors } = await fixture();
  try {
    bridge.accept(snapshot(1, [agent()]));
    await bridge.flush();
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].slice(0, 6), [
      "run",
      "--bg",
      "--json",
      "--no-notify",
      "--rm",
      "--parent",
    ]);
    assert.equal(calls[0][6], "t6");
    assert.equal(calls[0][12], process.execPath);
    const file = calls[0].at(-2)!;
    assert.equal(JSON.parse(await readFile(file, "utf8")).state, "working");
    bridge.accept(snapshot(2, [agent("idle")]));
    await bridge.flush();
    assert.equal(calls.length, 1);
    assert.equal(JSON.parse(await readFile(file, "utf8")).state, "idle");
    assert.deepEqual(errors, []);
  } finally {
    await bridge.dispose();
  }
  assert.deepEqual(calls[1], ["kill", "t1"]);
});

test("closed agents disappear; a working agent can reopen", async () => {
  const { bridge, calls } = await fixture();
  try {
    bridge.accept(snapshot(1, [agent()]));
    bridge.accept(snapshot(2, [agent("idle", true)]));
    await bridge.flush();
    assert.deepEqual(calls[1], ["kill", "t1"]);
    bridge.accept(snapshot(3, [agent("working", true)]));
    await bridge.flush();
    assert.equal(calls[2][0], "run");
    bridge.accept(snapshot(4, [], { type: "stopped" }));
    await bridge.flush();
    assert.equal(calls[3][0], "kill");
  } finally {
    await bridge.dispose();
  }
});

test("reject malformed, stale, foreign-session and post-disposal snapshots", async () => {
  const { bridge, calls } = await fixture();
  bridge.accept({});
  bridge.accept(snapshot(1, [agent()], { sessionId: "other" }));
  bridge.accept(snapshot(2, []));
  bridge.accept(snapshot(1, [agent()]));
  await bridge.flush();
  await bridge.dispose();
  bridge.accept(snapshot(3, [agent()]));
  await bridge.flush();
  assert.deepEqual(calls, []);
});

test("hc --rm exit/lookup race does not warn and still removes state", async () => {
  const errors: unknown[] = [];
  let file = "";
  const bridge = await createHerdrBridge({
    parent: "t6",
    sessionId: "session",
    cwd: "/repo",
    monitor: "/monitor.mjs",
    run: async (args) => {
      if (args[0] === "kill") throw { stderr: '{"error":{"kind":"not_found"}}' };
      file = args.at(-2)!;
      return '{"address":"t123"}';
    },
    onError: (error) => errors.push(error),
  });
  bridge.accept(snapshot(1, [agent()]));
  await bridge.flush();
  await bridge.dispose();
  assert.deepEqual(errors, []);
  await assert.rejects(readFile(file, "utf8"), { code: "ENOENT" });
});

test("shutdown during a pending launch cleans up the returned address", async () => {
  let release!: (value: string) => void;
  let started!: () => void;
  const ready = new Promise<void>((resolve) => {
    started = resolve;
  });
  const calls: string[][] = [];
  const bridge = await createHerdrBridge({
    parent: "t6",
    sessionId: "session",
    cwd: "/repo",
    monitor: "/monitor.mjs",
    run: async (args) => {
      calls.push(args);
      if (args[0] === "run") {
        started();
        return new Promise<string>((resolve) => {
          release = resolve;
        });
      }
      return "{}";
    },
    onError: () => {},
  });
  bridge.accept(snapshot(1, [agent()]));
  await ready;
  const stopped = bridge.dispose();
  release('{"address":"t123"}');
  await stopped;
  assert.deepEqual(calls[1], ["kill", "t123"]);
});
