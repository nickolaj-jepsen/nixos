import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout } from "node:timers/promises";

// No names/prompts can inject terminal controls. Keep the status title bounded.
export const cleanName = (name) =>
  String(name)
    .replace(/[\x00-\x1f\x7f-\x9f]/g, " ")
    .slice(0, 160);
export const statusOf = (state) =>
  ({
    working: "working",
    waiting: "idle",
    idle: "done",
    failed: "error",
    interrupted: "idle",
    skipped: "idle",
  })[state] ?? "idle";
export function renderMonitor(agent) {
  const name = cleanName(agent.name);
  const state = statusOf(agent.state);
  const msg = Buffer.from(`${name}: ${agent.state}`, "utf8").toString("base64");
  return (
    `\x1b]0;Pi agent: ${name}\x07\x1b]7501;state=${state}:app=pi:msg=${msg}\x1b\\` +
    `\x1b[2J\x1b[H${name}\nState: ${agent.state}\n\nRead-only Pi agent monitor.\nInspect or message this agent in the parent Pi session's /agents.\n`
  );
}

export async function monitor(file, parentPid) {
  // Never execute or forward text sent to this terminal.
  process.stdin.resume();
  process.stdin.on("data", () => {});
  let previous;
  try {
    for (;;) {
      try {
        process.kill(Number(parentPid), 0);
      } catch {
        break;
      }
      let value;
      try {
        value = await readFile(file, "utf8");
      } catch {
        break;
      }
      if (value !== previous) {
        const agent = JSON.parse(value);
        // The state is a fixed vocabulary, not untrusted display text.
        if (
          !["working", "waiting", "idle", "failed", "interrupted", "skipped"].includes(agent.state)
        )
          break;
        process.stdout.write(renderMonitor(agent));
        previous = value;
      }
      await setTimeout(300);
    }
  } finally {
    process.stdout.write("\x1b]7501;state=clear\x1b\\");
    process.stdin.pause();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await monitor(process.argv[2], process.argv[3]);
}
