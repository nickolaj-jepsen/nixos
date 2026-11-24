import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { cleanName, renderMonitor, statusOf } from "./monitor.mjs";

test("names cannot inject OSC/CSI controls; lifecycle mappings preserve meaning", () => {
  assert.ok(!/[\x00-\x1f\x7f-\x9f]/.test(cleanName("x\x1b]0;attack\x07\ny")));
  assert.equal(cleanName("x".repeat(300)).length, 160);
  assert.equal(statusOf("working"), "working");
  assert.equal(statusOf("waiting"), "idle");
  assert.equal(statusOf("idle"), "done");
  assert.equal(statusOf("failed"), "error");
  assert.equal(statusOf("interrupted"), "idle");
  const rendered = renderMonitor({ name: "researcher", state: "working" });
  assert.ok(rendered.includes("state=working:app=pi:"));
  assert.ok(rendered.includes("Read-only Pi agent monitor"));
});

test(
  "monitor renders state and exits if its state file disappears",
  { timeout: 5000 },
  async () => {
    const dir = await mkdtemp(join(tmpdir(), "herdr-monitor-test-"));
    const file = join(dir, "state.json");
    await writeFile(file, JSON.stringify({ name: "researcher", state: "working" }));
    const child = spawn(process.execPath, [
      fileURLToPath(new URL("./monitor.mjs", import.meta.url)),
      file,
      String(process.pid),
    ]);
    let output = "";
    child.stdout.on("data", (data) => {
      output += data;
    });
    try {
      await once(child.stdout, "data");
      await rm(file);
      const [code] = await once(child, "exit");
      assert.equal(code, 0);
      assert.ok(output.includes("State: working"));
      assert.ok(output.includes("state=clear"));
    } finally {
      child.kill();
      await rm(dir, { recursive: true, force: true });
    }
  },
);
