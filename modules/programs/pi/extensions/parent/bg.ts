/**
 * `bg_run`: a shell command detached from the turn, for builds and tests that
 * outlast a tool call. When it ends the session is woken with its exit code and
 * the tail of its output, so the common case needs no second read.
 *
 * Tasks belong to the session that started them: every shutdown (exit, /new,
 * /reload, a worktree move) kills them, and a late exit never reaches the next
 * session.
 */
import { spawn } from "node:child_process";
import { closeSync, fstatSync, mkdirSync, openSync, readdirSync, readSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { BG_RUN } from "../shared/tools.ts";

const STATUS = "bg";
const TAIL_LINES = 40;
const TAIL_BYTES = 4096;
// Font Awesome "terminal". One space follows it: these fonts draw it into its own cells.
const ICON = "";

type Session = { ctx: ExtensionContext; closed: boolean; next?: number; running: Set<number> };

/** The last lines of a log, at most `TAIL_BYTES`, without a line cut at the front. */
const tail = (path: string) => {
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - TAIL_BYTES);
    const buffer = Buffer.alloc(size - start);
    readSync(fd, buffer, 0, buffer.length, start);
    const lines = buffer.toString("utf8").replace(/\n$/, "").split("\n");
    if (start > 0 && lines.length > 1) lines.shift();
    return lines.slice(-TAIL_LINES).join("\n");
  } finally {
    closeSync(fd);
  }
};

export default function (pi: ExtensionAPI) {
  let session: Session | undefined;

  const showCount = (s: Session) =>
    s.ctx.ui.setStatus(
      STATUS,
      s.running.size > 0 ? `${ICON} ${s.running.size} running` : undefined,
    );

  pi.on("session_start", (_event, ctx) => {
    session = { ctx, closed: false, running: new Set() };
  });

  pi.on("session_shutdown", (_event, ctx) => {
    const s = session;
    session = undefined;
    if (!s) return;
    // Before the kills, so the exits they cause send nothing to a session that is gone.
    s.closed = true;
    for (const pid of s.running) {
      try {
        process.kill(-pid, "SIGTERM");
      } catch {}
    }
    ctx.ui.setStatus(STATUS, undefined);
  });

  pi.registerTool({
    name: BG_RUN,
    label: "Background",
    description: `Runs a shell command detached in the cwd and returns at once. When it ends you are woken with its exit code and last ${TAIL_LINES} lines. Use it for builds and tests longer than ~30 s. Full output is at the returned path; to stop it, \`kill -- -<pid>\`.`,
    parameters: Type.Object({
      command: Type.String({ description: "Bash command line" }),
      name: Type.Optional(Type.String({ description: "Short label for the wake message" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const s = session;
      if (!s) throw new Error("bg_run: no session");
      const dir = join(tmpdir(), "pi-bg", ctx.sessionManager.getSessionId());
      mkdirSync(dir, { recursive: true });
      // A reloaded or resumed session reuses its dir, and its transcript still points at the old logs.
      s.next ??= Math.max(0, ...readdirSync(dir).map((file) => Number.parseInt(file, 10) || 0)) + 1;
      const id = s.next++;
      const path = join(dir, `${id}.log`);
      const fd = openSync(path, "wx");
      const started = Date.now();
      // bash from PATH: the shell pi itself would pick is Apple's 3.2 on darwin.
      // Detached, so the task leads its own process group and one kill takes its children too.
      const child = spawn("bash", ["-c", params.command], {
        cwd: ctx.cwd,
        detached: true,
        stdio: ["ignore", fd, fd],
      });
      closeSync(fd);
      child.on("error", () => {});
      const pid = child.pid;
      if (pid === undefined) throw new Error("bg_run: bash could not be started");
      s.running.add(pid);
      showCount(s);

      const label = params.name ?? params.command.split("\n")[0].slice(0, 60);
      child.on("exit", (code, signal) => {
        // Its `cmd &` children outlive the session: a freed pid may lead another group by shutdown.
        s.running.delete(pid);
        if (s.closed) return;
        showCount(s);
        const status = code ?? signal;
        const seconds = Math.round((Date.now() - started) / 1000);
        let output: string;
        try {
          output = tail(path);
        } catch (error) {
          output = `(log unreadable: ${error instanceof Error ? error.message : String(error)})`;
        }
        pi.sendMessage(
          {
            customType: "bg-done",
            display: true,
            content: `#${id} ${JSON.stringify(label)} exited ${status} after ${seconds}s. Output: ${path}\n${output}`,
            details: { id, pid, path, code, signal, seconds },
          },
          { deliverAs: "followUp", triggerTurn: true },
        );
      });

      return {
        content: [{ type: "text", text: `#${id} started, pid ${pid}. Output: ${path}` }],
        details: { id, pid, path },
      };
    },
  });
}
