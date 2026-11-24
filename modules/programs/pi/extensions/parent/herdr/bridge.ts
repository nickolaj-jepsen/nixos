import { mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentTracker, parseSnapshot } from "../chrome/agents.ts";

type Run = (args: string[]) => Promise<string>;

function alreadyRemoved(error: unknown): boolean {
  if (!error || typeof error !== "object" || !("stderr" in error)) return false;
  try {
    return JSON.parse(String(error.stderr)).error?.kind === "not_found";
  } catch {
    return false;
  }
}

/** Status-only hc children: never start a model or forward input to an agent. */
export async function createHerdrBridge(options: {
  parent: string;
  sessionId: string;
  cwd: string;
  monitor: string;
  run: Run;
  onError: (error: unknown) => void;
}) {
  const dir = await mkdtemp(join(tmpdir(), "pi-herdr-"));
  const tracker = createAgentTracker(() => options.sessionId);
  const children = new Map<string, { address: string; file: string }>();
  let queue = Promise.resolve();
  let closed = false;
  let next = 0;

  const remove = async (id: string) => {
    const child = children.get(id);
    if (!child) return;
    // Kill only addresses we created; never resolve a user-controlled agent name.
    children.delete(id);
    try {
      await options.run(["kill", child.address]);
    } catch (error) {
      // hc kill can return not_found when --rm wins the exit/lookup race.
      if (!alreadyRemoved(error)) options.onError(error);
    } finally {
      await rm(child.file, { force: true });
    }
  };

  return {
    accept(value: unknown) {
      const snapshot = parseSnapshot(value);
      if (closed || !snapshot || !tracker.accept(snapshot)) return;
      const agents =
        snapshot.type === "stopped"
          ? []
          : snapshot.agents.filter((a) => !a.closed || a.state === "working");
      queue = queue
        .then(async () => {
          if (closed) return;
          const ids = new Set(agents.map((a) => a.id));
          for (const id of children.keys()) if (!ids.has(id)) await remove(id);
          for (const agent of agents) {
            if (closed) return;
            const child = children.get(agent.id);
            const file = child?.file ?? join(dir, `${++next}.json`);
            await writeFile(
              `${file}.tmp`,
              JSON.stringify({ name: agent.name, state: agent.state }),
              { mode: 0o600 },
            );
            await rename(`${file}.tmp`, file);
            if (child) continue;
            const output = await options.run([
              "run",
              "--bg",
              "--json",
              "--no-notify",
              "--rm",
              "--parent",
              options.parent,
              "--cwd",
              options.cwd,
              "--label",
              "fireproof.pi-agent-monitor=true",
              "--",
              process.execPath,
              options.monitor,
              file,
              String(process.pid),
            ]);
            const address: unknown = JSON.parse(output).address;
            if (typeof address !== "string" || !/^t[a-z0-9]+$/.test(address))
              throw new Error("hc returned an invalid monitor address");
            children.set(agent.id, { address, file });
          }
        })
        .catch(options.onError);
    },
    /** Also used by tests; lifecycle callbacks never block the event bus. */
    flush: () => queue,
    async dispose() {
      closed = true;
      await queue;
      // A monitor also exits when this file disappears or the Pi PID is gone.
      // Remove files even if hc is unavailable during logout/restart.
      for (const id of children.keys()) {
        try {
          await remove(id);
        } catch (error) {
          options.onError(error);
        }
      }
      await rm(dir, { recursive: true, force: true });
    },
  };
}
