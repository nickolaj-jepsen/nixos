import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import bridge from "../../core/agents-update.ts";

test("publication does not reload; explicit request waits until idle and acknowledges replacement runtime", async () => {
  const root = mkdtempSync(join(tmpdir(), "agents-bridge-test-"));
  const old = { ...process.env };
  let idle = false;
  let reloads = 0;
  let dispatchThrows = false;
  const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
  const commands = new Map<string, (args: string, ctx: unknown) => Promise<void>>();
  const messages: string[] = [];
  const ctx = {
    hasUI: true,
    isIdle: () => idle,
    sessionManager: { getSessionId: () => "test-session" },
    reload: async () => {
      reloads++;
      handlers.get("session_shutdown")!({ reason: "reload" }, ctx);
      bridge(api);
      handlers.get("session_start")!({ reason: "reload" }, ctx);
    },
  };
  const api = {
    on(name: string, handler: (event: unknown, ctx: unknown) => unknown) {
      handlers.set(name, handler);
    },
    registerCommand(
      name: string,
      options: { handler: (args: string, ctx: unknown) => Promise<void> },
    ) {
      commands.set(name, options.handler);
    },
    sendUserMessage(message: string) {
      if (dispatchThrows) throw new Error("transient dispatch failure");
      messages.push(message);
    },
  } as unknown as ExtensionAPI;
  try {
    process.env.XDG_STATE_HOME = root;
    process.env.AGENTS_UPDATES_ENABLED = "1";
    const refresh = join(root, "refresh");
    writeFileSync(refresh, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    process.env.AGENTS_REFRESH = refresh;
    delete process.env.AGENTS_BRIDGE_TOKEN;
    bridge(api);
    handlers.get("session_start")!({}, ctx);
    const sessions = join(root, "agents-updates/sessions");
    const entry = JSON.parse(readFileSync(join(sessions, readdirSync(sessions)[0]), "utf8"));
    assert.equal(entry.status, "busy");
    handlers.get("agent_settled")!({}, ctx);
    assert.equal(messages.length, 0);
    writeFileSync(entry.requestPath, JSON.stringify({ id: "request-1" }));
    handlers.get("agent_settled")!({}, ctx);
    assert.equal(messages.length, 0);
    idle = true;
    dispatchThrows = true;
    handlers.get("agent_settled")!({}, ctx);
    assert.equal(messages.length, 0);
    dispatchThrows = false;
    handlers.get("agent_settled")!({}, ctx);
    assert.equal(messages.length, 1);
    await commands.get(messages[0].slice(1))!("", ctx);
    assert.equal(reloads, 1);
    assert.equal(JSON.parse(readFileSync(`${entry.requestPath}.ack`, "utf8")).status, "applied");
    assert.equal(readdirSync(sessions).length, 1);
    writeFileSync(refresh, "#!/bin/sh\nexit 1\n", { mode: 0o700 });
    writeFileSync(entry.requestPath, JSON.stringify({ id: "request-2" }));
    handlers.get("agent_settled")!({}, ctx);
    await commands.get(messages[1].slice(1))!("", ctx);
    assert.equal(reloads, 1, "failed refresh must not reload");
    const failure = JSON.parse(readFileSync(`${entry.requestPath}.ack`, "utf8"));
    assert.equal(failure.id, "request-2");
    assert.equal(failure.status, "failed");
    writeFileSync(entry.requestPath, "{not json");
    handlers.get("agent_settled")!({}, ctx);
    await commands.get(messages[2].slice(1))!("", ctx);
    assert.match(JSON.parse(readFileSync(`${entry.requestPath}.ack`, "utf8")).message, /Malformed/);
    writeFileSync(entry.requestPath, JSON.stringify({ id: "request-3" }));
    handlers.get("agent_settled")!({}, ctx);
    assert.equal(messages.length, 4, "malformed request must not block the next valid request");
    // Simulate input cancellation: dispatch returned, but the command never ran.
    const now = Date.now;
    try {
      Date.now = () => now() + 11_000;
      handlers.get("agent_settled")!({}, ctx);
      assert.equal(messages.length, 5, "a dropped dispatch must eventually retry");
    } finally {
      Date.now = now;
    }
    handlers.get("session_shutdown")!({ reason: "quit" }, ctx);
    bridge(api);
    handlers.get("session_start")!({ reason: "startup" }, { ...ctx, hasUI: false });
    assert.equal(readdirSync(sessions).length, 0, "headless sessions must not advertise");
    process.env.AGENTS_PENDING_RELOAD = JSON.stringify({
      id: "stale",
      ackPath: `${entry.requestPath}.ack`,
    });
    bridge(api);
    handlers.get("session_start")!({ reason: "new" }, ctx);
    assert.equal(JSON.parse(readFileSync(`${entry.requestPath}.ack`, "utf8")).status, "failed");
  } finally {
    handlers.get("session_shutdown")?.({ reason: "quit" }, ctx);
    for (const key of Object.keys(process.env)) if (!(key in old)) delete process.env[key];
    Object.assign(process.env, old);
    rmSync(root, { recursive: true, force: true });
  }
});
