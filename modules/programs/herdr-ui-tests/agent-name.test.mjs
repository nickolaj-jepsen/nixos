import assert from "node:assert/strict";
import test from "node:test";
import { agentName } from "../herdr-ui/mods/nested-spaces/agent-name.js";
const claude = (title) => ({ title, app: "claude-code", program: { name: "Claude Code" } });
const pi = (title) => ({ title, app: "pi", program: { name: "Pi" } });
test("Claude's session name, without its working spinner", () => {
  assert.equal(agentName(claude("build-fix")), "build-fix");
  assert.equal(agentName(claude("✳ Fix login bug")), "Fix login bug");
  assert.equal(agentName(claude("⠂ Fix login bug")), "Fix login bug");
});
test("program names and folders are not names", () => {
  assert.equal(agentName(claude("Claude Code")), "");
  assert.equal(agentName(claude("✳ Claude Code")), "");
  assert.equal(agentName(pi("~/dev/agents · 2m")), "");
  assert.equal(agentName(pi("π - nixos")), "");
  assert.equal(agentName(pi("")), "");
  assert.equal(agentName({}), "");
});
test("Pi's named session title gives its name", () => {
  assert.equal(agentName(pi("π - herdr sidebar - nixos")), "herdr sidebar");
});
