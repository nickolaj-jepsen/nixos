import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Services } from "./services.ts";
import peerRegistry from "./peer-registry.ts";

const REQUEST = "agents:claude-peers:registry-request";
const METADATA = "agents:claude-peers:registry-metadata";

test("hub adapter publishes optional fields and clears them across turns", () => {
  const hooks = new Map<string, (event?: unknown, ctx?: unknown) => void>();
  const listeners = new Map<string, (event: unknown) => void>();
  const emitted: Array<{ channel: string; data: unknown }> = [];
  const pi = {
    on: (name: string, handler: (event?: unknown, ctx?: unknown) => void) =>
      hooks.set(name, handler),
    events: {
      on: (channel: string, handler: (event: unknown) => void) => {
        listeners.set(channel, handler);
        return () => listeners.delete(channel);
      },
      emit: (channel: string, data: unknown) => emitted.push({ channel, data }),
    },
  };
  let failure: string | undefined;
  let peer = true;
  let approvals = 0;
  const services = {
    identity: { failure: () => failure, peerTurn: () => peer },
    userWait: {
      beginAgentPrompt: () => {
        approvals++;
        return () => {
          approvals--;
        };
      },
    },
  };
  peerRegistry(pi as unknown as ExtensionAPI, services as unknown as Services);
  hooks.get("session_start")!({}, {});
  const approval = listeners.get("agents:claude-peers:approval-state")!;
  approval({ protocol: 99, waiting: true });
  assert.equal(approvals, 0);
  approval({ protocol: 1, waiting: true });
  approval({ protocol: 1, waiting: true });
  assert.equal(approvals, 1);
  approval({ protocol: 1, waiting: false });
  approval({ protocol: 1, waiting: false });
  assert.equal(approvals, 0);
  const latest = () => {
    const last = emitted.at(-1)!;
    assert.equal(last.channel, METADATA);
    const data = last.data as { protocol: number; metadata: Record<string, unknown> };
    assert.equal(data.protocol, 1);
    return data.metadata;
  };
  assert.equal(latest().hubPeer, undefined);
  hooks.get("agent_start")!();
  assert.equal(latest().hubPeer, true);
  failure = "API error";
  hooks.get("agent_settled")!();
  assert.equal(latest().hubFailed, "API error");
  assert.equal(latest().hubPeer, undefined);
  peer = false;
  hooks.get("agent_start")!();
  assert.equal(latest().hubFailed, undefined);
  assert.equal(latest().hubPeer, undefined);
  const count = emitted.length;
  listeners.get(REQUEST)!({ protocol: 99 });
  assert.equal(emitted.length, count);
  listeners.get(REQUEST)!({ protocol: 1 });
  assert.equal(emitted.length, count + 1);
  assert.deepEqual(Object.keys(latest()).sort(), ["hubFailed", "hubHidden", "hubPeer", "tmux"]);
  approval({ protocol: 1, waiting: true });
  hooks.get("session_shutdown")!();
  assert.equal(approvals, 0);
  assert.equal(listeners.has(REQUEST), false);
  assert.equal(listeners.has("agents:claude-peers:approval-state"), false);
});
