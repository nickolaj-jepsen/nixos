import assert from "node:assert/strict";
import test from "node:test";
import { createAgentContext } from "./context.ts";
const receipt = (agents: unknown[]) => ({
  receipt: { version: 1, graphs: [{ name: "group", agents }] },
});

test("binds resolved names/ids to public spawn context and resolved model", () => {
  const context = createAgentContext("/repo");
  context.start("call", "agent_spawn", {
    agents: [{ job: "Check the patch", cwd: "../worktree", model: "alias", name: "helper" }],
  });
  context.result("call", "agent_spawn", {
    details: receipt([{ name: "parent/helper", model: "actual-model" }]),
    structuredContent: { agents: [{ id: "id1", name: "parent/helper" }] },
  });
  assert.deepEqual(context.get("id1", "parent/helper"), {
    task: "Check the patch",
    cwd: "/worktree",
    model: "actual-model",
  });
  // Later receipts win over the cached spawn-time ID mapping.
  context.result("status", "agent_status", {
    details: receipt([{ name: "parent/helper", model: "new-model" }]),
  });
  assert.equal(context.get("id1", "parent/helper").model, "new-model");
});

test("reconstructs task and model on resume without persisted structuredContent", () => {
  const context = createAgentContext("/repo");
  context.restore([
    {
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "call",
            name: "agent_spawn",
            arguments: { agents: [{ job: "Run tests" }] },
          },
        ],
      },
    },
    {
      message: {
        role: "toolResult",
        toolCallId: "call",
        toolName: "agent_spawn",
        details: receipt([{ name: "verifier", model: "test-model" }]),
      },
    },
  ]);
  assert.deepEqual(context.get("new-live-id", "verifier"), {
    task: "Run tests",
    model: "test-model",
  });
});

test("mismatched receipts never guess task pairing; absent context remains absent", () => {
  const context = createAgentContext("/repo");
  context.start("call", "agent_spawn", { agents: [{ job: "secret task" }, { job: "another" }] });
  context.result("call", "agent_spawn", {
    details: receipt([{ name: "unknown", model: "model" }]),
  });
  assert.deepEqual(context.get("id", "unknown"), { model: "model" });
  assert.deepEqual(context.get("id2", "unseen"), {});
  context.start("bad", "agent_spawn", null);
  context.result("bad", "agent_spawn", null);
});

test("bounds task text, ignores model output and safely handles receipts without input", () => {
  const context = createAgentContext("/repo");
  context.result("call", "agent_status", {
    details: {
      receipt: {
        agents: [{ name: "worker", job: "x".repeat(10000), body: "private model output" }],
      },
    },
  });
  assert.equal(context.get("id", "worker").task?.length, 8000);
  assert.equal(JSON.stringify(context.get("id", "worker")).includes("private model output"), false);
});
