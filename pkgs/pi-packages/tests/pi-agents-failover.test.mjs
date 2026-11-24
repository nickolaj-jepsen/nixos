// Regression for pi-agents-failover.patch: a child agent's request runs
// through pi-durable's direct streamSimple, which Pi routes as `direct` and so
// drops the failed response and router state. With the patch, a 429 retry
// reaches the virtual router as `retry` and switches providers once.
//
// PI_AGENTS_DIR is the patched pi-agents package root (the Nix build sets it
// to $out/node_modules/pi-agents). PI_DEEPSEEK_ROUTER is the repo's router;
// the default relative path serves a checkout run.
import assert from "node:assert/strict";
import { chmodSync, copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { after, test } from "node:test";

const agents = process.env.PI_AGENTS_DIR;
if (!agents) throw new Error("PI_AGENTS_DIR must point at the patched pi-agents package");
const modulePath = join(agents, "src/host/virtual-model-routing.ts");
const routerPath =
  process.env.PI_DEEPSEEK_ROUTER ??
  new URL("../../../modules/programs/pi/extensions/core/deepseek-router.ts", import.meta.url)
    .pathname;

// Native ESM exposes named exports directly; jiti wraps a module without a
// default export in `default`, so accept either loader.
async function load(path) {
  const module = await import(pathToFileURL(path).href);
  const wrapped = module.default;
  return Object.keys(module).length === 1 && typeof wrapped === "object" && wrapped !== null
    ? wrapped
    : module;
}

// Node refuses to strip types under node_modules, and the build imports from
// $out. The module has no runtime imports, so a copy outside is enough.
const scratch = mkdtempSync(join(tmpdir(), "pi-agents-failover-module-"));
after(() => rmSync(scratch, { recursive: true, force: true }));
copyFileSync(modulePath, join(scratch, "virtual-model-routing.ts"));
const { withVirtualFailover } = await load(join(scratch, "virtual-model-routing.ts"));
const routerModule = await load(routerPath);
const register = [routerModule.default, routerModule].find((value) => typeof value === "function");
if (!register) throw new Error(`No default export in ${routerPath}`);

const go = {
  provider: "opencode-go",
  id: "deepseek-v4.1-flash",
  api: "openai-completions",
  maxTokens: 0,
};
const command = {
  provider: "command-code",
  id: "deepseek/deepseek-v4.1-flash",
  api: "openai-completions",
  maxTokens: 0,
};
const virtual = { provider: "auto", id: "deepseek-v4.1-flash", api: "pi-virtual", maxTokens: 0 };

let definition;

function message(overrides = {}) {
  return {
    role: "assistant",
    content: [],
    api: "openai-completions",
    provider: go.provider,
    model: go.id,
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp: Date.now(),
    ...overrides,
  };
}

function error(model, text) {
  return message({
    provider: model.provider,
    model: model.id,
    stopReason: "error",
    errorMessage: text,
  });
}

function user(text, timestamp) {
  return { role: "user", content: [{ type: "text", text }], timestamp };
}

// Durable storage rebuilds messages from JSON, so a retry's context holds new
// objects with the same content.
function roundtrip(messages) {
  return JSON.parse(JSON.stringify(messages));
}

// Pi's lazyStream: setup runs behind the returned stream and onResult sees the
// final message before result() settles.
function lazy(model, setup, observer, signal) {
  let settle;
  const result = new Promise((resolve) => (settle = resolve));
  (async () => {
    let final;
    try {
      const inner = await setup();
      for await (const event of inner) {
        if (event.type === "done") final = event.message;
        else if (event.type === "error") final = event.error;
      }
      if (typeof inner.result === "function") final = await inner.result();
    } catch (error) {
      final = message({
        api: model.api,
        provider: model.provider,
        model: model.id,
        stopReason: signal?.aborted ? "aborted" : "error",
        errorMessage: error instanceof Error ? error.message : String(error),
      });
    }
    observer?.onResult?.(final);
    settle(final);
  })();
  return { result: () => result, async *[Symbol.asyncIterator]() {} };
}

function latestSuccess(messages) {
  for (let index = messages.length - 1; index >= 0; index--) {
    const candidate = messages[index];
    if (candidate.role !== "assistant") continue;
    if (candidate.stopReason === "error" || candidate.stopReason === "aborted") continue;
    return candidate;
  }
}

function physical(provider, id) {
  return [go, command].find((model) => model.provider === provider && model.id === id);
}

function setup(t, behavior) {
  // Both providers have headroom, so the split would otherwise choose at random.
  t.mock.method(Math, "random", () => 0.9);
  const routed = [];
  const calls = [];
  const models = {
    streamSimple(model, context, options) {
      calls.push({ model, context, options });
      const final = behavior(model, calls.length);
      return { result: async () => final, async *[Symbol.asyncIterator]() {} };
    },
  };
  const runtime = {
    async resolveModel(model, messages, options) {
      routed.push({ model, messages, options });
      const previous = latestSuccess(messages);
      const previousModel = previous && physical(previous.provider, previous.model);
      const failedModel = options.failed && physical(options.failed.provider, options.failed.model);
      const route = await definition.route(
        {
          model,
          messages,
          reason: options.reason,
          thinkingLevel: options.thinkingLevel,
          ...(previousModel
            ? { previous: { model: previousModel, thinkingLevel: previous.thinkingLevel } }
            : {}),
          ...(failedModel
            ? {
                failed: {
                  model: failedModel,
                  thinkingLevel: options.failed.thinkingLevel,
                  message: options.failed,
                },
              }
            : {}),
          ...(options.state === undefined ? {} : { state: options.state }),
          ...(options.signal ? { signal: options.signal } : {}),
        },
        {
          modelRegistry: {
            find: (provider, id) =>
              [go, command].find((model) => model.provider === provider && model.id === id),
            hasConfiguredAuth: () => true,
          },
        },
      );
      return { model: route.model, thinkingLevel: route.thinkingLevel, state: route.state };
    },
  };
  const dir = mkdtempSync(join(tmpdir(), "pi-agents-failover-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const usage = join(dir, "ai-usage");
  // The shebang is this Node: `/bin/sh` is not part of the Nix build sandbox.
  const providers = [
    { id: "opencode-go", stale: false, error: null, windows: [{ label: "5h", usedPct: 30 }] },
    { id: "command-code", stale: false, error: null, windows: [{ label: "5h", usedPct: 30 }] },
  ];
  writeFileSync(
    usage,
    `#!${process.execPath}\nprocess.stdout.write(${JSON.stringify(JSON.stringify({ providers }))} + "\\n");\n`,
    { mode: 0o700 },
  );
  chmodSync(usage, 0o700);
  const original = process.env.PI_AI_USAGE_COMMAND;
  process.env.PI_AI_USAGE_COMMAND = usage;
  // The router reads the command once at registration.
  register({ registerVirtualModel: (value) => (definition = value) });
  t.after(() => {
    if (original === undefined) delete process.env.PI_AI_USAGE_COMMAND;
    else process.env.PI_AI_USAGE_COMMAND = original;
  });
  return { wrapper: withVirtualFailover(models, runtime, lazy), calls, routed };
}

test("a child 429 retry switches providers once and keeps the alternate sticky", async (t) => {
  const { wrapper, calls, routed } = setup(t, (model) =>
    model.provider === go.provider
      ? error(model, '429 {"error":{"type":"rate_limit"}}')
      : message({ provider: model.provider, model: model.id }),
  );
  const messages = [user("hello", 1)];
  const options = { sessionId: "child", reasoning: "low" };

  const failed = await wrapper.streamSimple(virtual, { messages }, options).result();
  assert.equal(failed.stopReason, "error");
  assert.equal(calls[0].model.provider, go.provider);

  // pi-durable's retry rebuilds the context without the failed assistant message.
  const retried = await wrapper
    .streamSimple(virtual, { messages: roundtrip(messages) }, options)
    .result();
  assert.equal(retried.stopReason, "stop");
  assert.equal(calls[1].model.provider, command.provider);
  assert.equal(routed[1].options.reason, "retry");
  assert.match(routed[1].options.failed.errorMessage, /429/);
  assert.deepEqual(routed[1].options.state, { provider: go.provider });

  // A later turn starts from the transcript: the alternate already answered.
  const next = roundtrip([
    ...messages,
    message({ provider: command.provider, model: command.id, timestamp: 2 }),
  ]);
  await wrapper.streamSimple(virtual, { messages: next }, options).result();
  assert.equal(calls[2].model.provider, command.provider);
  assert.equal(routed[2].options.reason, "direct");
  assert.equal(routed[2].options.failed, undefined);
});

test("a non-rate error retries on the same provider", async (t) => {
  const { wrapper, calls, routed } = setup(t, (model) =>
    model.provider === go.provider
      ? error(model, "401 Unauthorized")
      : message({ provider: model.provider, model: model.id }),
  );
  const messages = [user("hello", 1)];
  const options = { sessionId: "child", reasoning: "low" };

  await wrapper.streamSimple(virtual, { messages }, options).result();
  await wrapper.streamSimple(virtual, { messages: roundtrip(messages) }, options).result();
  assert.deepEqual(
    calls.map((call) => call.model.provider),
    [go.provider, go.provider],
  );
  assert.equal(routed[1].options.reason, "retry");
  assert.match(routed[1].options.failed.errorMessage, /401/);
});

test("a second 429 stays on the alternate instead of switching back", async (t) => {
  const { wrapper, calls, routed } = setup(t, (model) => error(model, "too many requests"));
  const messages = [user("hello", 1)];
  const options = { sessionId: "child", reasoning: "low" };

  await wrapper.streamSimple(virtual, { messages }, options).result();
  await wrapper.streamSimple(virtual, { messages: roundtrip(messages) }, options).result();
  await wrapper.streamSimple(virtual, { messages: roundtrip(messages) }, options).result();
  assert.deepEqual(
    calls.map((call) => call.model.provider),
    [go.provider, command.provider, command.provider],
  );
  assert.equal(routed[2].options.reason, "retry");
  assert.deepEqual(routed[2].options.state, { provider: command.provider, failedOver: true });
});

test("new input is not a retry, so no failed response is replayed", async (t) => {
  const { wrapper, routed } = setup(t, (model) => error(model, "429 rate limit"));
  const messages = [user("hello", 1)];
  const options = { sessionId: "child", reasoning: "low" };

  await wrapper.streamSimple(virtual, { messages }, options).result();
  await wrapper
    .streamSimple(virtual, { messages: roundtrip([...messages, user("again", 2)]) }, options)
    .result();
  assert.equal(routed[1].options.reason, "direct");
  assert.equal(routed[1].options.failed, undefined);
});

test("an aborted attempt keeps the signal and does not seed a retry chain", async (t) => {
  const { wrapper, routed } = setup(t, (model, attempt) =>
    attempt === 1
      ? error(model, "429 rate limit")
      : message({ provider: model.provider, model: model.id, stopReason: "aborted" }),
  );
  const messages = [user("hello", 1)];
  const options = { sessionId: "child", reasoning: "low" };

  await wrapper.streamSimple(virtual, { messages }, options).result();
  const signal = new AbortController().signal;
  const aborted = await wrapper
    .streamSimple(virtual, { messages: roundtrip(messages) }, { ...options, signal })
    .result();
  assert.equal(aborted.stopReason, "aborted");
  assert.equal(routed[1].options.signal, signal);
  await wrapper.streamSimple(virtual, { messages: roundtrip(messages) }, options).result();
  assert.equal(routed[2].options.reason, "direct");
});

test("resolveModels wraps the runtime that pi-durable receives", () => {
  const source = readFileSync(join(agents, "src/host/models.ts"), "utf8");
  assert.match(source, /withVirtualFailover\(runtime, runtime, lazyStream\)/);
});
