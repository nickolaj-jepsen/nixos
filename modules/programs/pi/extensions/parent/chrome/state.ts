import type { CustomEditor, ExtensionContext } from "@earendil-works/pi-coding-agent";

export type Renderer = { requestRender(): void; getFocusedComponent?(): unknown };
/** Where a click landed: its terminal column, and the width of what was clicked. */
export type ClickAt = { column: number; columns: number };
export type Action = (ctx: ExtensionContext, at?: ClickAt) => void | Promise<void>;

/** State shared by the chrome modules; one instance per extension load. */
export type ChromeState = {
  /** Set once at session_start; its getters read the live session. */
  ctx: ExtensionContext | undefined;
  /**
   * Whether the session draws pi's TUI. A headless one (`pi -p`, RPC) shows
   * none of this, so it runs no git, gh or ai-usage call.
   */
  live: boolean;
  tui: Renderer | undefined;
  /** The prompt editor; pi copies its app keybinding handlers onto it, so clicks can reuse them. */
  editor: CustomEditor | undefined;
  /**
   * Set by each render that draws the top border, cleared by the footer's: the
   * footer renders after the editor, and nothing renders the editor while a
   * dialog holds its slot.
   */
  borderDrawn: boolean;
  /** Group of the clickable thing under the pointer; footer parts and the `label` on the top border. */
  hover: string | undefined;
  /** Moves the hover; it lapses on its own because pi never reports the pointer leaving. */
  setHover(group: string | undefined): void;
};

// A resting pointer sends nothing, so this also bounds a hover whose exit pi never saw.
const HOVER_MS = 1500;

export const createState = (): ChromeState => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const state: ChromeState = {
    ctx: undefined,
    live: false,
    tui: undefined,
    editor: undefined,
    borderDrawn: false,
    hover: undefined,
    setHover: (group) => {
      if (timer) clearTimeout(timer);
      timer = group ? setTimeout(() => state.setHover(undefined), HOVER_MS) : undefined;
      timer?.unref?.();
      if (state.hover === group) return;
      state.hover = group;
      state.tui?.requestRender();
    },
  };
  return state;
};
