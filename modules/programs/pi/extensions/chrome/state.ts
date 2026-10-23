import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export type Renderer = { requestRender(): void; getFocusedComponent?(): unknown };
export type Action = (ctx: ExtensionContext) => void | Promise<void>;

/** State shared by the chrome modules; one instance per extension load. */
export type ChromeState = {
  ctx: ExtensionContext | undefined;
  tui: Renderer | undefined;
  /** pi copies its app keybinding handlers onto a CustomEditor, so clicks can reuse them. */
  editor: { actionHandlers?: Map<string, () => void> } | undefined;
  /** What pi focuses while the prompt is active: the wrapper around `editor`. */
  editorComponent: unknown;
  /** Group of the clickable thing under the pointer; footer parts and the `label` on the top border. */
  hover: string | undefined;
  /** Moves the hover; it lapses on its own because pi never reports the pointer leaving. */
  setHover(group: string | undefined): void;
  /** Whether the editor wrapper has drawn the top border with the measurements; the footer shows them while false. */
  metersActive: boolean;
};

// Terminals that implement OSC 22 show a hand over a control; the rest ignore it.
const POINTER_HAND = "\x1b]22;pointer\x1b\\";
const POINTER_DEFAULT = "\x1b]22;\x1b\\";

const setPointer = (hand: boolean) => {
  if (process.stdout.isTTY) process.stdout.write(hand ? POINTER_HAND : POINTER_DEFAULT);
};

// A resting pointer sends nothing, so this also bounds a hover whose exit pi never saw.
const HOVER_MS = 1500;

export const createState = (): ChromeState => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const state: ChromeState = {
    ctx: undefined,
    tui: undefined,
    editor: undefined,
    editorComponent: undefined,
    hover: undefined,
    setHover: (group) => {
      if (timer) clearTimeout(timer);
      timer = group ? setTimeout(() => state.setHover(undefined), HOVER_MS) : undefined;
      timer?.unref?.();
      if (state.hover === group) return;
      if ((state.hover === undefined) !== (group === undefined)) setPointer(group !== undefined);
      state.hover = group;
      state.tui?.requestRender();
    },
    metersActive: false,
  };
  return state;
};
