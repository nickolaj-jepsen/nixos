/**
 * The terminal title: the only surface visible from the niri overview, so it
 * stays terse. Task label, directory, age, and a state word only when the
 * session wants you.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { UserWait } from "../lib/user-wait.ts";
import { shortPath } from "../lib/format.ts";
import type { Identity } from "../identity.ts";
import type { ChromeState } from "./state.ts";

const TICK_MS = 60_000;
const WORK_GLYPH = "⠿";

const formatAge = (ms: number) => {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
};

export const createTitle = (
  pi: ExtensionAPI,
  state: ChromeState,
  label: Identity,
  userWait: UserWait,
) => {
  let timer: ReturnType<typeof setInterval> | undefined;
  let repaintTimer: ReturnType<typeof setTimeout> | undefined;
  let cwd = process.cwd();
  let since = Date.now();
  let waited = false;
  let painted = "";

  const render = (ctx: ExtensionContext) => {
    const text = label.current(ctx)?.text;
    const word = label.stateWord(ctx);
    // A frozen frame, not the animation: the title is rewritten by the OS.
    const lead = label.working() ? `${WORK_GLYPH} ` : "";
    return `${lead}${text ? `${text} · ` : ""}${shortPath(cwd)} · ${formatAge(Date.now() - since)}${
      word ? ` · ${word}` : ""
    }`;
  };

  const paint = () => {
    const ctx = state.ctx;
    if (!ctx || !state.live) return;
    // Every tool call repaints; only rewrite the title when it changed, so the
    // titlebar does not flicker for a session that merely got older.
    const title = render(ctx);
    if (title !== painted) {
      painted = title;
      ctx.ui.setTitle(title);
    }
    state.tui?.requestRender();
  };

  /**
   * Pi owns the title too (`π - <name> - <cwd>`) and rewrites it on startup and
   * whenever the session name changes, which includes our own auto-naming. Win
   * that race once per rename instead of on every render.
   */
  const repaintSoon = () => {
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = setTimeout(() => {
      repaintTimer = undefined;
      painted = "";
      paint();
    }, 250);
    repaintTimer.unref?.();
  };

  label.onChange(paint);

  pi.on("session_start", (_event, ctx) => {
    cwd = ctx.cwd;
    if (!state.live) return;
    timer = setInterval(paint, TICK_MS);
    timer.unref?.();
    paint();
    repaintSoon();
  });

  const restart = () => {
    since = Date.now();
    paint();
  };
  pi.on("agent_start", restart);
  pi.on("agent_settled", restart);

  // Only a dialog the run is blocked on says "waiting"; the phase underneath is
  // untouched, so the spinner stays and a run that settles meanwhile shows it.
  const promptChanged = (ctx: ExtensionContext) => {
    const waiting = userWait.waitingOnUser(ctx);
    if (waiting !== waited) {
      waited = waiting;
      since = Date.now();
    }
    paint();
  };
  pi.on("ui_prompt_start", (_event, ctx) => promptChanged(ctx));
  pi.on("ui_prompt_end", (_event, ctx) => promptChanged(ctx));

  pi.on("message_end", paint);
  pi.on("tool_execution_end", paint);
  pi.on("session_compact", paint);
  pi.on("session_info_changed", () => {
    paint();
    repaintSoon();
  });

  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    if (repaintTimer) clearTimeout(repaintTimer);
    repaintTimer = undefined;
    if (state.ctx && state.live) {
      // Leave an honest title for the shell prompt that follows; the fish title
      // takes over from here, but a crash-free exit should not show a stale run.
      const text = label.current(state.ctx)?.text;
      state.ctx.ui.setTitle(`${text ? `${text} · ` : ""}${shortPath(cwd)}`);
    }
  });
};
