/**
 * Per-session memory state. One runtime serves the parent and every subagent
 * session, so state is keyed by session id, never by cwd alone.
 *
 * `injected` is the system-prompt text and is fixed when the session starts, so
 * the cached prompt prefix survives writes. `hot` tracks the stores as they are
 * now, for the footer and for telling the model where a fresh save will land.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
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
    const { hot } = get(ctx);
    // The chrome footer drops statuses first when the line is tight; keep it short.
    const parts = [`mem ${compact(hot.used)}/${compact(hot.budget)}`];
    if (hot.cold > 0) parts.push(`${hot.cold} cold`);
    if (hot.stale > 0) parts.push(`${hot.stale} stale`);
    ctx.ui.setStatus("memory", parts.join(" · "));
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
      if (ctx.hasUI) ctx.ui.setStatus("memory", undefined);
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

/** 1840 → "1.8k", for the footer. */
const compact = (count: number) =>
  count >= 1000 ? `${(count / 1000).toFixed(1)}k` : String(count);
