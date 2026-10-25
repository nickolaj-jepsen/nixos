/**
 * Per-session memory state. One runtime serves the parent and every subagent
 * session, so state is keyed by session id, never by cwd alone.
 *
 * `injected` is the system-prompt text and is fixed when the session starts, so
 * the cached prompt prefix survives writes. `hot` tracks the stores as they are
 * now, for the footer and for telling the model where a fresh save will land.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { publishMemoryTally } from "../../shared/memory-tally.ts";
import { isSubagentSession } from "../../shared/subagent-session.ts";
import { buildHotSection, type HotIndex } from "./hot.ts";
import {
  invalidateAll,
  invalidateStore,
  loadStoreCached,
  resolveScope,
  type Scope,
  type Store,
} from "./store.ts";
import { verifyRecent } from "./verify.ts";

export type SessionState = {
  scope: Scope;
  hot: HotIndex;
  injected: string;
  subagent: boolean;
  /** Context files and appended rules of the last run; empty before the first one. */
  contextText: string;
};

export type Sessions = ReturnType<typeof createSessions>;

const buildHot = (scope: Scope) =>
  buildHotSection(
    scope.visible.flatMap((store) => loadStoreCached(store)),
    verifyRecent,
  );

export function createSessions() {
  const states = new Map<string, SessionState>();

  const get = (ctx: ExtensionContext): SessionState => {
    const id = ctx.sessionManager.getSessionId();
    const known = states.get(id);
    if (known && known.scope.cwd === ctx.cwd) return known;
    const scope = resolveScope(ctx.cwd);
    const hot = buildHot(scope);
    const subagent = isSubagentSession(ctx);
    const state: SessionState = { scope, hot, injected: hot.text, subagent, contextText: "" };
    states.set(id, state);
    return state;
  };

  const setStatus = (ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    const state = get(ctx);
    const { hot } = state;
    // The count is what the next session is given; characters of budget are not a
    // unit a reader can feel, so they stay in the panel. The text doubles as the
    // repaint signal: chrome paints the segment from the tallies published below.
    const count = hot.picks.length;
    ctx.ui.setStatus(
      "memory",
      count === 0 ? undefined : `✦ ${count}${hot.stale > 0 ? ` · ${hot.stale} stale` : ""}`,
    );
    // One process serves the parent and its children; only the parent draws a footer.
    if (!state.subagent) publishMemoryTally({ count, stale: hot.stale, cold: hot.cold });
  };

  return {
    get,
    setStatus,

    /** Starts a fresh session state and freezes its prompt text. */
    begin(ctx: ExtensionContext): SessionState {
      states.delete(ctx.sessionManager.getSessionId());
      invalidateAll();
      const state = get(ctx);
      setStatus(ctx);
      return state;
    },

    end(ctx: ExtensionContext) {
      states.delete(ctx.sessionManager.getSessionId());
      if (!ctx.hasUI) return;
      ctx.ui.setStatus("memory", undefined);
      if (!isSubagentSession(ctx)) publishMemoryTally(undefined);
    },

    /** Re-reads the stores after a write; the injected prompt text stays as it was. */
    refresh(ctx: ExtensionContext, store?: Store) {
      if (store) invalidateStore(store);
      const state = get(ctx);
      state.hot = buildHot(state.scope);
      setStatus(ctx);
    },
  };
}
