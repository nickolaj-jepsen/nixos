import { CustomEditor, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import { hitTest, isPlainClick, type Region } from "./layout.ts";
import type { Action, ChromeState } from "./state.ts";

type Border = (text: string) => string;
type Inner = {
  render(width: number): string[];
  handleMouse?(event: TuiMouseEvent): unknown;
  borderColor?: Border;
  renderedAutocompleteHeight?: unknown;
  actionHandlers?: Map<string, () => void>;
};

export type Painters = {
  top: (width: number, hidden: number, border: Border) => { line: string; regions: Region[] };
  bottom: (width: number, hidden: number, border: Border) => string | undefined;
  /** Clicks on the top border outside any region. */
  topClick: Action;
};

const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;
const plain = (line: string) => line.replace(ANSI, "");
const topHidden = (line: string) => Number(/↑\s*(\d+)\s*more/.exec(plain(line))?.[1] ?? 0);
// pi's bottom border: dashes, optionally around a ` ↓ N more ` scroll label.
const BOTTOM = /^─*(?: ↓ (\d+) more )?─*$/;

/**
 * Owns both editor borders without owning the editor: another extension
 * (spellfix) installs pi's custom editor and only one factory can exist, so this
 * wraps whatever factory is installed. The proxy forwards everything pi wires up
 * (submit, text, keybindings, border color) and intercepts only `render` and
 * `handleMouse`; the borders are rewritten after the inner render, so spellfix's
 * styling never reaches them.
 */
export const createEditorChrome = (state: ChromeState, painters: Painters) => {
  let topRegions: Region[] = [];
  let installed: unknown;

  const decorate = (inner: Inner, tui: { requestRender(): void }) => {
    state.tui = tui;
    state.editor = inner;
    return new Proxy(inner, {
      get(target, property) {
        if (property === "render") {
          return (width: number) => {
            const lines = target.render(width);
            if (!state.ctx || width <= 0 || lines.length === 0) return lines;
            // Resolved per render: pi assigns the border color after the factory
            // returns, and that is the one that tracks thinking level and bash mode.
            const color = target.borderColor;
            const border: Border =
              typeof color === "function" ? color.bind(target) : (text) => text;

            const top = painters.top(width, topHidden(lines[0] ?? ""), border);
            lines[0] = top.line;
            topRegions = top.regions;

            // The autocomplete list renders below the bottom border.
            const below = target.renderedAutocompleteHeight;
            const index = lines.length - 1 - (typeof below === "number" ? below : 0);
            const match = index > 0 ? BOTTOM.exec(plain(lines[index] ?? "")) : null;
            const gauge = match ? painters.bottom(width, Number(match[1] ?? 0), border) : undefined;
            if (gauge !== undefined) lines[index] = gauge;
            const active = gauge !== undefined;
            if (active !== state.gaugeActive) {
              state.gaugeActive = active;
              // The footer reads this flag; repaint after this frame, not inside it.
              setTimeout(() => state.tui?.requestRender(), 0);
            }
            return lines;
          };
        }
        if (property === "handleMouse") {
          return (event: TuiMouseEvent) => {
            // Only the top border row: the input keeps its click-to-place-cursor.
            if (event.y === 0 && isPlainClick(event)) {
              const ctx = state.ctx;
              const action = hitTest(topRegions, event.x) ?? painters.topClick;
              if (ctx)
                void Promise.resolve()
                  .then(() => action(ctx))
                  .catch(() => {});
              return { handled: true };
            }
            return target.handleMouse?.(event);
          };
        }
        return Reflect.get(target, property, target);
      },
      set(target, property, value) {
        return Reflect.set(target, property, value, target);
      },
      has(target, property) {
        return Reflect.has(target, property);
      },
    });
  };

  /**
   * Runs after the startup handlers and wraps whatever editor factory it finds;
   * when nothing installed one, it supplies pi's default CustomEditor.
   */
  const ensureInstalled = (ctx: ExtensionContext) => {
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    const previous = ctx.ui.getEditorComponent();
    if (previous && previous === installed) return;
    const factory = (tui: never, theme: never, keybindings: never) => {
      const inner = previous
        ? previous(tui, theme, keybindings)
        : new CustomEditor(tui, theme, keybindings, { embedWorkingStatus: true });
      return decorate(inner as never, tui);
    };
    installed = factory;
    ctx.ui.setEditorComponent(factory as never);
  };

  return { ensureInstalled };
};
