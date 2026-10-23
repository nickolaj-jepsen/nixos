/**
 * Points TMPDIR at a private `pi-run-*` dir under the system temp dir and
 * deletes it when pi exits, so pi's own output files (truncated bash logs,
 * codemode output, pasted images), the bash tool's children and the model's
 * scratch files stop piling up there. The path goes into the system prompt
 * because the read/write tools don't expand `$TMPDIR`.
 *
 * Scoped to the process rather than the session: subagents run in-process,
 * fire their own session_start/session_shutdown and share `process.env` with
 * the parent. A crash or SIGKILL leaves the dir to the OS's temp-dir aging.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { recordOriginalTmpdir } from "./lib/original-tmpdir.ts";

// On globalThis so /reload and subagent sessions, which load their own copy of
// this module, reuse the one dir instead of each making (and deleting) another.
const KEY = Symbol.for("fireproof.pi.tmpdir");
const store = globalThis as { [KEY]?: string };

const scratchDir = () => {
  const existing = store[KEY];
  if (existing) return existing;
  recordOriginalTmpdir();
  const dir = mkdtempSync(join(tmpdir(), "pi-run-"));
  store[KEY] = dir;
  // node's tmpdir() rereads this on every call, and the bash tool spawns with process.env.
  process.env.TMPDIR = dir;
  process.once("exit", () => rmSync(dir, { recursive: true, force: true }));
  return dir;
};

const guideline = (dir: string) =>
  `Your scratch dir is \`${dir}\` (also \`$TMPDIR\`): put throwaway files there, not in /tmp, ~ or the repo. Pi deletes it when this process exits, so don't clean it up yourself and don't keep anything there that must outlive the session.`;

export default function (pi: ExtensionAPI) {
  pi.on("session_start", () => {
    scratchDir();
  });

  pi.on("before_agent_start", (event) => {
    const line = guideline(scratchDir());
    const guidelines = event.systemPromptOptions.promptGuidelines;
    if (!guidelines.includes(line)) guidelines.push(line);
  });
}
