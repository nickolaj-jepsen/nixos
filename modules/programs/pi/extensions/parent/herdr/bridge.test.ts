import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createHerdrBridge } from "./bridge.ts";
const snapshot = (sequence: number, state = "working", extra = {}) => ({
  protocol: 1,
  sessionId: "session",
  instanceId: "instance",
  sequence,
  type: "snapshot",
  agents: [{ id: "agent", name: "researcher", state, closed: false }],
  ...extra,
});
async function fixture() {
  const calls: string[][] = [];
  const errors: unknown[] = [];
  const live = new Map<
    string,
    { address: string; parent: string; state: string; labels: Record<string, string> }
  >();
  let count = 0;
  let fail = "";
  let hasContext = true;
  const bridge = await createHerdrBridge({
    parent: "t6",
    sessionId: "session",
    cwd: "/repo",
    monitor: "/monitor.mjs",
    context: () => (hasContext ? { task: "Verify the fix", model: "test-model" } : {}),
    run: async (args) => {
      calls.push(args);
      if (args[0] === "run") {
        if (fail === "before") {
          fail = "";
          throw new Error("core down");
        }
        const address = `t${++count}`;
        const labels: Record<string, string> = {};
        args.forEach((arg, i) => {
          if (arg === "--label") {
            const [key, ...value] = args[i + 1].split("=");
            labels[key] = value.join("=");
          }
        });
        live.set(address, { address, parent: "t6", state: "live", labels });
        if (fail === "reply") {
          fail = "";
          throw new Error("reply lost");
        }
        return JSON.stringify({ address });
      }
      if (args[0] === "ls") {
        if (fail === "list" || fail === "partial") {
          const result = fail === "list" ? "{}" : '{"terminals":[]}';
          fail = "";
          return result;
        }
        // Actual hc ls --json omits labels; only get returns full records.
        return JSON.stringify({
          terminals: [...live.values()].map(({ address, parent, state }) => ({
            address,
            parent,
            state,
          })),
        });
      }
      if (args[0] === "get") {
        if (!live.has(args[1])) throw { stderr: '{"error":{"kind":"not_found"}}' };
        return JSON.stringify(live.get(args[1]));
      }
      if (args[0] === "label") {
        for (const label of args.slice(2)) {
          const [key, ...value] = label.split("=");
          live.get(args[1])!.labels[key] = value.join("=");
        }
      }
      if (args[0] === "kill") {
        live.delete(args[1]);
        if (fail === "removed") {
          fail = "";
          throw { stderr: '{"error":{"kind":"not_found"}}' };
        }
      }
      return "{}";
    },
    onError: (error) => errors.push(error),
  });
  return {
    bridge,
    calls,
    errors,
    live,
    fault: (value: string) => {
      fail = value;
    },
    runs: () => calls.filter((c) => c[0] === "run"),
    clearContext: () => {
      hasContext = false;
    },
  };
}

test("one terminal per agent, rich state file and updated sidebar labels", async () => {
  const f = await fixture();
  try {
    f.bridge.accept(snapshot(1));
    await f.bridge.flush();
    const args = f.runs()[0];
    assert.ok(args.includes("--no-notify"));
    assert.ok(args.includes("--rm"));
    assert.equal(args[args.indexOf("--parent") + 1], "t6");
    assert.equal(args[args.indexOf("--") + 1], process.execPath);
    const file = args.at(-2)!;
    const initial = JSON.parse(await readFile(file, "utf8"));
    assert.equal(initial.task, "Verify the fix");
    assert.equal(initial.model, "test-model");
    f.bridge.accept(snapshot(2, "idle"));
    await f.bridge.flush();
    assert.equal(f.runs().length, 1);
    assert.equal(f.live.get("t1")!.labels["fireproof.pi-agent-name"], "researcher");
    assert.equal(f.live.get("t1")!.labels["fireproof.pi-agent-state"], "idle");
    const record = JSON.parse(await readFile(file, "utf8"));
    assert.equal(record.startedAt, initial.startedAt);
    assert.deepEqual(
      record.history.map((h: { state: string }) => h.state),
      ["working", "idle"],
    );
    f.clearContext();
    await f.bridge.refresh();
    const withoutContext = JSON.parse(await readFile(file, "utf8"));
    assert.equal(withoutContext.task, undefined);
    assert.equal(withoutContext.model, undefined);
    assert.deepEqual(f.errors, []);
  } finally {
    await f.bridge.dispose();
  }
  assert.equal(f.live.size, 0);
});

test("health check recreates a lost terminal without duplicating live children", async () => {
  const f = await fixture();
  try {
    f.bridge.accept(snapshot(1));
    await f.bridge.flush();
    await f.bridge.refresh();
    assert.equal(f.runs().length, 1);
    f.fault("partial");
    await f.bridge.refresh();
    assert.equal(f.runs().length, 1);
    f.live.clear();
    await f.bridge.refresh();
    assert.equal(f.runs().length, 2);
    await f.bridge.refresh();
    assert.equal(f.live.size, 1);
  } finally {
    await f.bridge.dispose();
  }
});

test("failed spawn retries; lost spawn reply adopts the already-created child", async () => {
  for (const fault of ["before", "reply"]) {
    const f = await fixture();
    try {
      f.fault(fault);
      f.bridge.accept(snapshot(1));
      await f.bridge.flush();
      assert.equal(f.errors.length, 1);
      await f.bridge.refresh();
      assert.equal(f.live.size, 1);
      assert.equal(f.bridge.status().monitors, 1);
      assert.equal(f.runs().length, fault === "reply" ? 1 : 2);
      assert.equal(f.bridge.status().lastError, undefined);
    } finally {
      await f.bridge.dispose();
    }
  }
});

test("bad lists and foreign labels never delete or take ownership of unrelated terminals", async () => {
  const f = await fixture();
  try {
    f.bridge.accept(snapshot(1));
    await f.bridge.flush();
    f.live.set("tforeign", {
      address: "tforeign",
      parent: "t6",
      state: "live",
      labels: { "fireproof.pi-owner": "another-owner" },
    });
    f.fault("list");
    await f.bridge.refresh();
    assert.equal(f.runs().length, 1);
    await f.bridge.refresh();
    assert.ok(f.live.has("tforeign"));
  } finally {
    await f.bridge.dispose();
  }
  assert.ok(f.live.has("tforeign"));
});

test("stale, foreign, stopped, closed and post-disposal snapshots", async () => {
  const f = await fixture();
  f.bridge.accept({});
  f.bridge.accept(snapshot(1, "working", { sessionId: "other" }));
  assert.equal(f.calls.length, 0);
  f.bridge.accept(snapshot(2));
  await f.bridge.flush();
  f.bridge.accept(snapshot(1, "failed"));
  await f.bridge.flush();
  assert.equal(f.live.get("t1")!.labels["fireproof.pi-agent-state"], "working");
  f.bridge.accept(
    snapshot(3, "idle", {
      agents: [{ id: "agent", name: "researcher", state: "idle", closed: true }],
    }),
  );
  await f.bridge.flush();
  assert.equal(f.live.size, 0);
  f.bridge.accept(snapshot(4));
  await f.bridge.flush();
  f.bridge.accept(snapshot(5, "idle", { type: "stopped", agents: [] }));
  await f.bridge.flush();
  assert.equal(f.live.size, 0);
  await f.bridge.dispose();
  f.bridge.accept(snapshot(6));
  await f.bridge.refresh();
  assert.equal(f.live.size, 0);
});

test("coalesces queued snapshots and tolerates hc --rm exit/lookup race", async () => {
  const f = await fixture();
  f.bridge.accept(snapshot(1));
  f.bridge.accept(snapshot(2, "idle", { type: "stopped", agents: [] }));
  await f.bridge.flush();
  assert.equal(f.runs().length, 0);
  f.bridge.accept(snapshot(3));
  await f.bridge.flush();
  const file = f.runs()[0].at(-2)!;
  f.fault("removed");
  await f.bridge.dispose();
  assert.deepEqual(f.errors, []);
  await assert.rejects(readFile(file), { code: "ENOENT" });
});

test("shutdown during launch cleans up the returned address", async () => {
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
      if (args[0] === "get") {
        const owner = calls[0].find((arg) => arg.startsWith("fireproof.pi-owner="))!.split("=")[1];
        return JSON.stringify({ parent: "t6", labels: { "fireproof.pi-owner": owner } });
      }
      return "{}";
    },
    onError: () => {},
  });
  bridge.accept(snapshot(1));
  await ready;
  const stopped = bridge.dispose();
  release('{"address":"t123"}');
  await stopped;
  assert.deepEqual(calls.at(-1), ["kill", "t123"]);
});
