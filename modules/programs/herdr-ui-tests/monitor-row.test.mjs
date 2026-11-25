import assert from "node:assert/strict";
import test from "node:test";
import { monitorRow } from "../herdr-ui/mods/nested-spaces/monitor-row.js";
const terminal = (name, state) => ({ title: "Pi agent: old name", labels: { "fireproof.pi-agent-monitor": "true", "fireproof.pi-agent-name": name, "fireproof.pi-agent-state": state } });
test("normal agent and shell rows are unchanged", () => {
  assert.equal(monitorRow({ title: "main", git: { ahead: 3 } }, {}), undefined);
  assert.equal(monitorRow({ plain: true }), undefined);
});
test("monitor identities replace inherited branch names", () => {
  const row = monitorRow({ title: "main", git: { ahead: 3 } }, terminal("verifier", "working"));
  assert.equal(row.name, "verifier"); assert.equal(row.label, "Working");
  assert.ok(row.tooltip.includes("Read-only"));
  assert.equal(row.tooltip.includes("main"), false);
});
test("waiting is not user-blocked; failures and completion have honest labels", () => {
  assert.equal(monitorRow({}, terminal("a", "waiting")).tone, "idle");
  assert.equal(monitorRow({}, terminal("a", "failed")).label, "Failed");
  assert.equal(monitorRow({}, terminal("a", "idle")).label, "Finished");
});
test("legacy monitors use their title; hostile text and prototype keys are harmless", () => {
  assert.equal(monitorRow({}, { title: "Pi agent: legacy", labels: { "fireproof.pi-agent-monitor": "true" } }).name, "legacy");
  const row = monitorRow({}, terminal("abc\x1b]0;spoof\x07\u202e", "constructor"));
  assert.equal(row.name, "abc"); assert.equal(row.label, "Monitor");
  assert.ok(monitorRow({}, terminal("x".repeat(1000), "working")).name.length <= 160);
});
