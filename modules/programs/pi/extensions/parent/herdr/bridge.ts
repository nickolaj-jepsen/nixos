import { randomUUID, createHash } from "node:crypto";
import { mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentTracker, parseSnapshot, type AgentLifecycle } from "../chrome/agents.ts";

type Run = (args: string[]) => Promise<string>;
export type AgentContext = { task?: string; model?: string; cwd?: string };
type RecordState = AgentLifecycle &
  AgentContext & {
    parent: string;
    sessionId: string;
    startedAt: number;
    updatedAt: number;
    history: { state: string; at: number }[];
  };
type Terminal = {
  address: string;
  parent?: string;
  state?: string;
  labels?: Record<string, string>;
};
const cleanLabel = (value: string) =>
  value.replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, " ").slice(0, 160);
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
  context?: (id: string, name: string) => AgentContext;
  onError: (error: unknown) => void;
}) {
  const dir = await mkdtemp(join(tmpdir(), "pi-herdr-"));
  const owner = randomUUID();
  const tracker = createAgentTracker(() => options.sessionId);
  const desired = new Map<string, RecordState>();
  const children = new Map<
    string,
    { address: string; file: string; content?: string; labels?: string }
  >();
  let queue = Promise.resolve();
  let closed = false;
  let lastError: string | undefined;
  const report = (error: unknown) => {
    lastError = error instanceof Error ? error.message : String(error);
    options.onError(error);
  };
  const fileFor = (id: string) =>
    join(dir, `${createHash("sha256").update(id).digest("hex")}.json`);
  const kill = async (address: string) => {
    try {
      // An old address is not permission to kill a terminal on a replaced core.
      const terminal: Terminal = JSON.parse(await options.run(["get", address, "--json"]));
      if (terminal?.parent !== options.parent || terminal.labels?.["fireproof.pi-owner"] !== owner)
        return;
      await options.run(["kill", address]);
    } catch (error) {
      if (!alreadyRemoved(error)) throw error;
    }
  };
  const remove = async (id: string) => {
    const child = children.get(id);
    if (!child) return;
    children.delete(id);
    try {
      await kill(child.address);
    } catch (error) {
      report(error);
    } finally {
      await rm(child.file, { force: true });
    }
  };
  const sync = async () => {
    if (closed) return;
    for (const id of children.keys()) if (!desired.has(id)) await remove(id);
    for (const [id, record] of desired) {
      if (closed) return;
      try {
        if (options.context) {
          const context = options.context(id, record.name);
          // Navigating Pi's tree can remove the spawn call from the active
          // branch. Don't keep showing context from an abandoned branch.
          record.task = context.task;
          record.model = context.model;
          record.cwd = context.cwd || options.cwd;
        }
        const child = children.get(id);
        const file = child?.file ?? fileFor(id);
        const content = JSON.stringify(record);
        if (content !== child?.content) {
          await writeFile(`${file}.tmp`, content, { mode: 0o600 });
          await rename(`${file}.tmp`, file);
        }
        const labels = [
          "fireproof.pi-agent-monitor=true",
          `fireproof.pi-owner=${owner}`,
          `fireproof.pi-agent-id=${id}`,
          `fireproof.pi-session=${options.sessionId}`,
          `fireproof.pi-agent-name=${cleanLabel(record.name)}`,
          `fireproof.pi-agent-state=${record.state}`,
        ];
        if (child) {
          if (child.labels !== labels.join("\n"))
            await options.run(["label", child.address, ...labels]);
          child.labels = labels.join("\n");
          child.content = content;
          continue;
        }
        const output = await options.run([
          "run",
          "--bg",
          "--json",
          "--no-notify",
          "--rm",
          "--parent",
          options.parent,
          "--cwd",
          record.cwd || options.cwd,
          ...labels.flatMap((label) => ["--label", label]),
          "--",
          process.execPath,
          options.monitor,
          file,
          String(process.pid),
        ]);
        const address: unknown = JSON.parse(output).address;
        if (typeof address !== "string" || !/^t[a-z0-9]+$/.test(address))
          throw new Error("hc returned an invalid monitor address");
        children.set(id, { address, file, content, labels: labels.join("\n") });
      } catch (error) {
        report(error);
      }
    }
  };
  const enqueue = (work: () => Promise<void>) => {
    queue = queue.then(work).catch(report);
    return queue;
  };
  return {
    accept(value: unknown) {
      const snapshot = parseSnapshot(value);
      if (closed || !snapshot || !tracker.accept(snapshot)) return;
      const agents =
        snapshot.type === "stopped"
          ? []
          : snapshot.agents.filter((a) => !a.closed || a.state === "working");
      const ids = new Set(agents.map((a) => a.id));
      for (const id of desired.keys()) if (!ids.has(id)) desired.delete(id);
      for (const agent of agents) {
        const old = desired.get(agent.id);
        const now = Date.now();
        const changed = old?.state !== agent.state;
        desired.set(agent.id, {
          ...old,
          ...agent,
          cwd: old?.cwd ?? options.cwd,
          parent: options.parent,
          sessionId: options.sessionId,
          startedAt: old?.startedAt ?? now,
          updatedAt: changed ? now : old!.updatedAt,
          history: changed
            ? [...(old?.history ?? []), { state: agent.state, at: now }].slice(-8)
            : old!.history,
        });
      }
      void enqueue(sync);
    },
    /** Reconcile live ownership, including launches whose CLI reply was lost. */
    refresh() {
      return enqueue(async () => {
        if (closed) return;
        const response: unknown = JSON.parse(
          await options.run(["ls", "--json", "--label", `fireproof.pi-owner=${owner}`]),
        );
        if (
          !response ||
          typeof response !== "object" ||
          !("terminals" in response) ||
          !Array.isArray(response.terminals)
        )
          throw new Error("Invalid hc terminal list");
        // `hc ls` is a compact summary even with --json: it omits labels.
        // Fetch full records before deciding ownership or adopting a lost reply.
        const records: Terminal[] = [];
        for (const summary of response.terminals as Terminal[]) {
          if (!summary || !/^t[a-z0-9]+$/.test(summary.address)) continue;
          try {
            records.push(JSON.parse(await options.run(["get", summary.address, "--json"])));
          } catch (error) {
            if (!alreadyRemoved(error)) throw error;
          }
        }
        const live = records.filter(
          (t) =>
            /^t[a-z0-9]+$/.test(t.address) &&
            t.parent === options.parent &&
            t.state === "live" &&
            t.labels?.["fireproof.pi-owner"] === owner,
        );
        const addresses = new Set(live.map((t) => t.address));
        for (const [id, child] of children) {
          if (addresses.has(child.address)) continue;
          // A partial list during core recovery is not proof a monitor died.
          try {
            const terminal: Terminal = JSON.parse(
              await options.run(["get", child.address, "--json"]),
            );
            if (
              terminal?.state === "live" &&
              terminal.parent === options.parent &&
              terminal.labels?.["fireproof.pi-owner"] === owner
            ) {
              live.push(terminal);
              addresses.add(terminal.address);
              continue;
            }
          } catch (error) {
            if (!alreadyRemoved(error)) throw error;
          }
          children.delete(id);
        }
        for (const terminal of live) {
          const id = terminal.labels?.["fireproof.pi-agent-id"];
          if (!id || !desired.has(id)) {
            await kill(terminal.address);
            continue;
          }
          if (!children.has(id)) children.set(id, { address: terminal.address, file: fileFor(id) });
          else if (children.get(id)!.address !== terminal.address) await kill(terminal.address);
        }
        lastError = undefined;
        await sync();
      });
    },
    flush: () => queue,
    status: () => ({ agents: desired.size, monitors: children.size, lastError }),
    async dispose() {
      closed = true;
      await queue;
      for (const id of children.keys()) {
        try {
          await remove(id);
        } catch (error) {
          report(error);
        }
      }
      await rm(dir, { recursive: true, force: true });
    },
  };
}
