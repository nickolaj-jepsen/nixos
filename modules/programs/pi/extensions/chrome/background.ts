import type { Theme, ThemeColor } from "@earendil-works/pi-coding-agent";
import type { Part } from "./layout.ts";
import type { Action } from "./state.ts";

// `pi-background-tasks` publishes its footer line as prose for a human reader:
// " bg 2 running · Shift↓ · /bg-clear ". Only the counts carry information here;
// the key and command hints are dropped because the segment is clickable.
const COUNT = /^(\d+) (running|failed|stopped|done)$/;

// Same cadence as pi's working indicator, but the eight-dot braille frames: the
// four-dot ones sit high in the cell instead of filling its height.
const FRAMES = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"];
const FRAME_MS = 80;

// Font Awesome glyphs; the amount already gives each one a space, so the glyph
// itself carries none.
const GLYPHS: Record<string, string> = {
  done: "\uf00c",
  failed: "\uf071",
  stopped: "\uf04d",
};

// Only a state worth noticing leaves the neutral colour.
const COLORS: Record<string, ThemeColor> = {
  failed: "error",
  stopped: "warning",
};

type Badge = { status: string; text: string };

const badgesOf = (text: string, frame: number): Badge[] =>
  text
    // The package labels the whole line with "bg "; the brackets label it here.
    .replace(/^bg\s+/, "")
    .split("·")
    .map((token) => COUNT.exec(token.trim()))
    .filter((match): match is RegExpExecArray => match !== null)
    .map(([, amount, status]) => ({
      status,
      text: `${status === "running" ? FRAMES[frame] : (GLYPHS[status] ?? status)} ${amount}`,
    }));

/**
 * The background-task footer segment: one bracketed group of state badges, a
 * spinner while a task runs, painted as a single part so it hovers and clicks as
 * one control. `open` enters the task dock, `close` leaves it again.
 *
 * `repaint` runs once per animation frame, and the spinner ticks only while a
 * render has shown a running task. `parts` takes the package's status text, or
 * `undefined` when it published none, and drops whatever carries no count, such
 * as the package's update notice: the segment exists for the clickable counts.
 */
export const createBackground = (repaint: () => void) => {
  let frame = 0;
  let timer: ReturnType<typeof setInterval> | undefined;

  const spin = (spinning: boolean) => {
    if (spinning === (timer !== undefined)) return;
    if (timer) {
      clearInterval(timer);
      timer = undefined;
    }
    if (!spinning) {
      frame = 0;
      return;
    }
    timer = setInterval(() => {
      frame = (frame + 1) % FRAMES.length;
      repaint();
    }, FRAME_MS);
    timer.unref?.();
  };

  return {
    parts: (text: string | undefined, open: Action, close: Action): Part[] => {
      const badges = text === undefined ? [] : badgesOf(text, frame);
      spin(badges.some(({ status }) => status === "running"));
      if (badges.length === 0) return [];
      // The package marks its open dock with this word instead of an entry hint.
      const dockOpen = text !== undefined && /\bfocused\b/.test(text);
      const paint = (theme: Theme) =>
        [
          theme.fg("dim", "["),
          ...badges.map(
            ({ status, text }, index) =>
              `${index === 0 ? "" : " "}${theme.fg(COLORS[status] ?? "dim", text)}`,
          ),
          theme.fg("dim", "]"),
        ].join("");
      return [
        {
          id: "bg",
          text: `[${badges.map(({ text }) => text).join(" ")}]`,
          color: "dim",
          styled: paint,
          action: dockOpen ? close : open,
        },
      ];
    },
    dispose: () => spin(false),
  };
};
