import type { Part } from "./layout.ts";
import type { Action } from "./state.ts";

// Font Awesome "users". One space follows the glyph: these fonts draw it into
// its own cells, so a second one reads as a gap.
const ICON_AGENTS = "";

/** Channels pi-agents publishes its child lifecycle on, independent of its UI. */
export const AGENTS_STATE_EVENT = "pi-agents:state";
export const AGENTS_STATE_REQUEST_EVENT = "pi-agents:state:request";

const PROTOCOL = 1;

export const AGENT_STATES = [
  "working",
  "waiting",
  "idle",
  "failed",
  "interrupted",
  "skipped",
] as const;

export type AgentLifecycleState = (typeof AGENT_STATES)[number];

/** The lifecycle fields of a snapshot entry; prompts and results stay in pi-agents. */
export type AgentLifecycle = {
  id: string;
  name: string;
  state: AgentLifecycleState;
  closed: boolean;
};

/** One complete replacement snapshot of a session publisher's agents. */
export type AgentsSnapshot = {
  protocol: 1;
  sessionId: string;
  instanceId: string;
  sequence: number;
  type: "snapshot" | "stopped";
  agents: readonly AgentLifecycle[];
};

export type AgentCounts = { working: number; waiting: number };

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const isAgent = (value: unknown): value is AgentLifecycle =>
  isRecord(value) &&
  typeof value.id === "string" &&
  typeof value.name === "string" &&
  typeof value.closed === "boolean" &&
  typeof value.state === "string" &&
  (AGENT_STATES as readonly string[]).includes(value.state);

/** A whole snapshot, or `undefined`: a partial one would invent counts. */
export const parseSnapshot = (value: unknown): AgentsSnapshot | undefined => {
  if (!isRecord(value) || value.protocol !== PROTOCOL) return undefined;
  if (typeof value.sessionId !== "string" || value.sessionId === "") return undefined;
  if (typeof value.instanceId !== "string" || value.instanceId === "") return undefined;
  if (typeof value.sequence !== "number" || !Number.isInteger(value.sequence)) return undefined;
  if (value.sequence < 1) return undefined;
  if (value.type !== "snapshot" && value.type !== "stopped") return undefined;
  if (!Array.isArray(value.agents) || !value.agents.every(isAgent)) return undefined;
  return value as AgentsSnapshot;
};

/**
 * How many agents work, and how many wait for the inputs of the graph node they
 * belong to. A closed agent that is not working again is closed, not its last
 * state: messaging it is what reopens it. `queued` is not a state here: an
 * answer held for delivery belongs to an idle agent, which is neither working
 * nor waiting on dependencies.
 */
export const agentCounts = (agents: readonly AgentLifecycle[]): AgentCounts => {
  let working = 0;
  let waiting = 0;
  for (const agent of agents) {
    if (agent.closed && agent.state !== "working") continue;
    if (agent.state === "working") working++;
    else if (agent.state === "waiting") waiting++;
  }
  return { working, waiting };
};

/**
 * The agent footer segment: one glyph and the working and waiting tallies,
 * painted as a single part so it hovers and clicks as one control; `open` shows
 * the full list. Empty when no agent works or waits.
 */
export const agentParts = (counts: AgentCounts, open: Action): Part[] => {
  const { working, waiting } = counts;
  if (working === 0 && waiting === 0) return [];
  return [
    {
      id: "agents",
      text: `${ICON_AGENTS} ${working}${waiting > 0 ? ` +${waiting}` : ""}`,
      color: "dim",
      action: open,
    },
  ];
};

export type AgentTracker = {
  /** Takes one event; false for a duplicate, stale, malformed or other-session snapshot. */
  accept(value: unknown): boolean;
  counts(): AgentCounts;
  /** Forget the publisher: the next snapshot starts a new lifetime. */
  reset(): void;
};

/**
 * Follows one publisher's snapshots. They replace the previous state, and a
 * `stopped` one clears it: stopped means the process no longer owns the agents,
 * not that their durable work finished, because another process may resume it.
 */
export const createAgentTracker = (
  sessionId: () => string | undefined = () => undefined,
): AgentTracker => {
  let instanceId: string | undefined;
  let sequence = 0;
  let agents: readonly AgentLifecycle[] = [];
  return {
    accept(value) {
      const snapshot = parseSnapshot(value);
      if (!snapshot) return false;
      // A snapshot from a replaced session would resurrect its counts.
      const current = sessionId();
      if (current !== undefined && snapshot.sessionId !== current) return false;
      if (snapshot.instanceId === instanceId) {
        // Duplicates and late snapshots are older news than the one held.
        if (snapshot.sequence <= sequence) return false;
      } else {
        // A new publisher lifetime numbers its snapshots from one again.
        instanceId = snapshot.instanceId;
        sequence = 0;
      }
      sequence = snapshot.sequence;
      agents = snapshot.type === "stopped" ? [] : snapshot.agents;
      return true;
    },
    counts: () => agentCounts(agents),
    reset() {
      instanceId = undefined;
      sequence = 0;
      agents = [];
    },
  };
};

export type AgentStateSource = {
  tracker: AgentTracker;
  /** Forces a snapshot: load order and a listener attached mid-session both need it. */
  request(): void;
  dispose(): void;
};

type Events = {
  on(channel: string, handler: (data: unknown) => void): () => void;
  emit(channel: string, data: unknown): void;
};

/**
 * Listens for the package's snapshots and asks for one now. The request is
 * emitted outside the listener: pi-agents answers synchronously, so requesting
 * from inside it would re-enter the listener.
 */
export const createAgentState = (
  events: Events,
  onChange: () => void,
  sessionId: () => string | undefined = () => undefined,
): AgentStateSource => {
  const tracker = createAgentTracker(sessionId);
  const unsubscribe = events.on(AGENTS_STATE_EVENT, (value) => {
    if (tracker.accept(value)) onChange();
  });
  const request = () => events.emit(AGENTS_STATE_REQUEST_EVENT, { protocol: PROTOCOL });
  request();
  return { tracker, request, dispose: () => unsubscribe() };
};
