/**
 * Whether the agent is blocked on the user: a dialog is open while a tool call
 * is in flight, as with a permission ask or a question tool, or a dialog an
 * extension opened on the agent's behalf outside a tool call. A dialog opened
 * between runs, such as a menu the user called up, does not count.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type SessionWait = { prompting: boolean; tools: Set<string>; agentPrompts: number };

// On globalThis because each extension loads its own copy of this module, and
// all of them must read the state whichever one's handlers keep it.
const KEY = Symbol.for("fireproof.pi.user-wait");
const store = globalThis as { [KEY]?: Map<string, SessionWait> };
const sessions = (store[KEY] ??= new Map());

const state = (ctx: ExtensionContext): SessionWait => {
  const id = ctx.sessionManager.getSessionId();
  let wait = sessions.get(id);
  if (!wait) sessions.set(id, (wait = { prompting: false, tools: new Set(), agentPrompts: 0 }));
  return wait;
};

/**
 * Registers the handlers that keep the state `waitingOnUser` reads, per
 * session. The updates are idempotent, so every consumer calls this; call it
 * before registering a `ui_prompt_start` handler that reads the state.
 */
export function trackUserWait(pi: ExtensionAPI): void {
  // tool_execution_start fires before tool_call hooks, so a permission ask counts as in flight.
  pi.on("tool_execution_start", (event, ctx) => {
    state(ctx).tools.add(event.toolCallId);
  });
  pi.on("tool_execution_end", (event, ctx) => {
    state(ctx).tools.delete(event.toolCallId);
  });
  pi.on("agent_settled", (_event, ctx) => {
    state(ctx).tools.clear();
  });
  pi.on("ui_prompt_start", (_event, ctx) => {
    state(ctx).prompting = true;
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    state(ctx).prompting = false;
  });
  pi.on("session_shutdown", (_event, ctx) => {
    sessions.delete(ctx.sessionManager.getSessionId());
  });
}

/**
 * Runs `open`, which opens one dialog in `ctx`'s UI, and counts that dialog as
 * the agent waiting on the user until it settles. Use it for a dialog raised
 * on the agent's behalf while no tool call of `ctx`'s session may be in flight.
 */
export async function markAgentPrompt<T>(
  ctx: ExtensionContext,
  open: () => Promise<T>,
): Promise<T> {
  // Set before `open` runs: pi emits ui_prompt_start on a later microtask.
  const wait = state(ctx);
  wait.agentPrompts++;
  try {
    return await open();
  } finally {
    wait.agentPrompts--;
  }
}

/** True while `ctx`'s session has a dialog open and a tool call or `markAgentPrompt` dialog in flight. */
export function waitingOnUser(ctx: ExtensionContext): boolean {
  const wait = sessions.get(ctx.sessionManager.getSessionId());
  return !!wait?.prompting && (wait.tools.size > 0 || wait.agentPrompts > 0);
}
