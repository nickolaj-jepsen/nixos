export const clean = (value) =>
  typeof value === "string"
    ? value
        .replace(/\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]P^_][\s\S]*?(?:\x07|\x1b\\)/g, " ")
        .replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, " ")
        .trim()
        .slice(0, 160)
    : "";
const STATES = new Map([
  ["working", { label: "Working", tone: "working" }],
  ["waiting", { label: "Waiting", tone: "idle" }],
  ["idle", { label: "Finished", tone: "done" }],
  ["failed", { label: "Failed", tone: "blocked" }],
  ["interrupted", { label: "Interrupted", tone: "idle" }],
  ["skipped", { label: "Skipped", tone: "idle" }],
]);

/** Monitor rows are agent identities, never duplicate Git checkout summaries. */
export function monitorRow(agent, terminal) {
  const labels = terminal?.labels ?? agent?.labels;
  if (labels?.["fireproof.pi-agent-monitor"] !== "true") return undefined;
  const title = clean(terminal?.title || agent?.title);
  const name =
    clean(labels["fireproof.pi-agent-name"]) || title.replace(/^Pi agent:\s*/, "") || "Pi agent";
  const state = STATES.get(labels["fireproof.pi-agent-state"]) ?? {
    label: "Monitor",
    tone: "idle",
  };
  return {
    name,
    ...state,
    tooltip: `${name} · ${state.label}\nRead-only Pi child monitor. Click to inspect; use the parent Pi /agents to message it.`,
  };
}
