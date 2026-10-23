/**
 * Asks before the first chrome-devtools MCP call of a session; a yes covers the
 * rest of it. pi-permission-system can't express this: its session approval
 * for an MCP tool covers only that one tool, so every browser tool would ask.
 *
 * The answer is process-wide: in-process subagents have no UI of their own, so
 * their first call asks in the UI session's dialog, naming the subagent, and
 * shares that session's approval. Concurrent asks share one prompt. Nested calls
 * (codemode scripts) go through `tool_call` too, so they are gated. With no UI
 * session in the process (print mode), the browser stays blocked.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Pi's tool-name spelling of the `chrome-devtools` server in the pi leaf's MCP config.
const PREFIX = "mcp__chrome_devtools__";
const ALLOW = "Allow for this session";

type Gate = {
  approved: boolean;
  asking?: Promise<boolean>;
  // The UI session's select, and the extension instance that registered it.
  ask?: (title: string, options: string[]) => Promise<string | undefined>;
  owner?: object;
};

// On globalThis because every session, subagents included, loads its own copy of this module.
const KEY = Symbol.for("fireproof.pi.browser-gate");
const store = globalThis as { [KEY]?: Gate };
const gate = (store[KEY] ??= { approved: false });

const approve = (ask: NonNullable<Gate["ask"]>, title: string) => {
  const owner = gate.owner;
  const asking = ask(title, [ALLOW, "Deny"])
    .then((choice) => {
      const yes = choice === ALLOW;
      // A dialog torn down with its session must not approve the next one.
      if (gate.owner === owner) gate.approved = yes;
      return yes;
    })
    .finally(() => {
      if (gate.asking === asking) gate.asking = undefined;
    });
  return (gate.asking = asking);
};

export default function (pi: ExtensionAPI) {
  const self = {};

  // Re-registered on every UI session start: a ctx captured before a session
  // replacement or /reload is stale.
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    gate.approved = false;
    gate.asking = undefined;
    gate.owner = self;
    gate.ask = (title, options) => ctx.ui.select(title, options);
  });

  pi.on("session_shutdown", () => {
    if (gate.owner !== self) return;
    gate.owner = gate.ask = gate.asking = undefined;
  });

  pi.on("tool_call", async (event, ctx) => {
    if (gate.approved || !event.toolName.startsWith(PREFIX)) return;
    if (!gate.ask)
      return {
        block: true,
        reason:
          "The browser needs the user's approval, and no pi session in this process has a UI to ask in. Don't retry; leave browser work to an interactive pi session and report what you would have checked.",
      };

    const name = pi.getSessionName();
    const requester = ctx.hasUI ? "The agent" : name ? `Subagent ${name}` : "A subagent";
    const title = `${requester} wants to drive a browser (chrome-devtools, a throwaway profile).`;
    if (await (gate.asking ?? approve(gate.ask, title))) return;
    return {
      block: true,
      reason: "The user denied browser use for now; don't retry unless asked.",
    };
  });
}
