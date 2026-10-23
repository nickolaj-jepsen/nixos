/**
 * Whether a run is blocked on the user: a dialog is open while a tool call is
 * in flight, as with a permission ask or a question tool. A dialog opened
 * between runs, such as a menu the user called up, does not count.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type SessionWait = { prompting: boolean; tools: Set<string> };

// On globalThis because each extension loads its own copy of this module, and
// all of them must read the state whichever one's handlers keep it.
const KEY = Symbol.for("fireproof.pi.user-wait");
const store = globalThis as { [KEY]?: Map<string, SessionWait> };
const sessions = (store[KEY] ??= new Map());

const state = (ctx: ExtensionContext): SessionWait => {
  const id = ctx.sessionManager.getSessionId();
  let wait = sessions.get(id);
  if (!wait) sessions.set(id, (wait = { prompting: false, tools: new Set() }));
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

/** True while `ctx`'s session has a dialog open and a tool call in flight. */
export function waitingOnUser(ctx: ExtensionContext): boolean {
  const wait = sessions.get(ctx.sessionManager.getSessionId());
  return !!wait?.prompting && wait.tools.size > 0;
}
