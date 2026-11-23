import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import register from "../extensions/core/deepseek-router.ts";

const go = { provider: "opencode-go", id: "deepseek-v4.1-flash" };
const command = { provider: "command-code", id: "deepseek/deepseek-v4.1-flash" };

function usage(model, usedPct, label = "5h", extra = {}) {
  return { id: model.provider, stale: false, error: null, windows: [{ label, usedPct }], ...extra };
}

function setup(t, { unavailable = [] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "deepseek-router-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, "ai-usage");
  const ctx = {
    modelRegistry: {
      find: (provider, id) => [go, command].find((m) => m.provider === provider && m.id === id),
      hasConfiguredAuth: (model) => !unavailable.includes(model),
    },
  };
  let definition;
  const original = process.env.PI_AI_USAGE_COMMAND;
  try {
    process.env.PI_AI_USAGE_COMMAND = path;
    register({ registerVirtualModel: (value) => (definition = value) });
  } finally {
    if (original === undefined) delete process.env.PI_AI_USAGE_COMMAND;
    else process.env.PI_AI_USAGE_COMMAND = original;
  }
  return {
    route: (request = {}) =>
      definition.route({ reason: "user", thinkingLevel: "low", ...request }, ctx),
    setUsage: (...providers) =>
      writeFileSync(path, `#!/bin/sh\nprintf '%s\\n' '${JSON.stringify({ providers })}'\n`, {
        mode: 0o700,
      }),
  };
}

function retry(model, state, errorMessage = '429 {"error":{"type":"rate_limit"}}') {
  return {
    reason: "retry",
    state,
    failed: { model, thinkingLevel: "high", message: { stopReason: "error", errorMessage } },
  };
}

test("splits new branches at 80/20 only when both providers have >20% left", async (t) => {
  const { route, setUsage } = setup(t);
  let roll = 0.799;
  t.mock.method(Math, "random", () => roll);
  setUsage(usage(go, 53, "month"), usage(command, 65, "7d"));
  assert.equal((await route()).model, command);
  roll = 0.8;
  assert.equal((await route()).model, go);
  setUsage(usage(go, 80, "month"), usage(command, 65));
  assert.equal((await route()).model, command);
  roll = 0;
  setUsage(usage(go, 53), usage(command, 80, "7d"));
  assert.equal((await route()).model, go);
});

test("uses tightest windows and falls back deterministically when neither is ready", async (t) => {
  const { route, setUsage } = setup(t);
  const random = t.mock.method(Math, "random", () => 0);
  setUsage(
    usage(go, 85),
    usage(command, 0, "5h", {
      windows: [
        { label: "5h", usedPct: 0 },
        { label: "month", usedPct: 84 },
      ],
    }),
  );
  assert.equal((await route()).model, command);
  setUsage(usage(go, 85), usage(command, 85));
  assert.equal((await route()).model, go);
  setUsage(usage(go, 70), usage(command, 0, "5h", { stale: true, error: "offline" }));
  assert.equal((await route()).model, go);
  assert.equal(random.mock.callCount(), 0);
});

test("keeps existing state, a manual model choice, and direct calls sticky", async (t) => {
  const { route, setUsage } = setup(t);
  setUsage(usage(go, 30), usage(command, 95));
  const state = { provider: command.provider };
  assert.equal((await route({ state })).state, state);
  assert.equal((await route({ state })).model, command);
  assert.equal((await route({ previous: { model: command } })).model, command);
  assert.equal((await route({ reason: "direct", previous: { model: command } })).model, command);
  assert.equal((await route(retry(command, state, "503 Service Unavailable"))).model, command);
});

test("switches once per 429 retry chain and stays on a successful alternate", async (t) => {
  const { route, setUsage } = setup(t);
  setUsage(usage(go, 30), usage(command, 30));
  const first = await route(retry(go, { provider: go.provider }));
  assert.equal(first.model, command);
  assert.equal(first.thinkingLevel, "high");
  const second = await route(retry(command, first.state));
  assert.equal(second.model, command);
  assert.equal(second.state, first.state);
  const continuation = await route({
    reason: "continuation",
    previous: { model: command },
    state: second.state,
  });
  assert.equal(continuation.model, command);
  assert.deepEqual(continuation.state, { provider: command.provider });
  assert.equal((await route(retry(command, continuation.state, "Too many requests"))).model, go);
});

test("does not fail over to an alternate with low or stale quota", async (t) => {
  const { route, setUsage } = setup(t);
  const state = { provider: go.provider };
  setUsage(usage(command, 80));
  assert.equal((await route(retry(go, state))).state, state);
  setUsage(usage(command, 40, "5h", { stale: true, error: "offline" }));
  assert.equal((await route(retry(go, state))).model, go);
});

test("keeps requests working when usage or alternate auth is unavailable", async (t) => {
  const { route, setUsage } = setup(t, { unavailable: [command] });
  assert.equal((await route()).model, go);
  assert.equal((await route(retry(command, { provider: command.provider }))).model, command);
  setUsage(usage(command, 10));
  assert.equal((await route(retry(go, { provider: go.provider }))).model, go);
});
