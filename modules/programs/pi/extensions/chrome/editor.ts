import { CustomEditor, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import { hitTest, hoverAt, isPlainClick, type Region } from "./layout.ts";
import type { Action, ChromeState, Renderer } from "./state.ts";

type Border = (text: string) => string;
type Inner = {
  render(width: number): string[];
  handleMouse?(event: TuiMouseEvent): unknown;
  borderColor?: Border;
  actionHandlers?: Map<string, () => void>;
};

export type Painters = {
  top: (width: number, hidden: number, border: Border) => { line: string; regions: Region[] };
};

const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;
const plain = (line: string) => line.replace(ANSI, "");
const topHidden = (line: string) => Number(/↑\s*(\d+)\s*more/.exec(plain(line))?.[1] ?? 0);

/**
 * Whether pi mounted a widget directly above the editor. It puts the
 * above-editor container immediately before the editor's own, seeded with a
 * spacer row, so a widget makes it hold more than that one child. Anything
 * unexpected counts as "no widget": the blank row is spacing, not information,
 * and must not appear on its own.
 */
const widgetAbove = (state: ChromeState): boolean => {
  const mounted = (state.tui as { children?: Array<{ children?: unknown[] }> } | undefined)
    ?.children;
  if (!Array.isArray(mounted)) return false;
  const index = mounted.findIndex((child) => child.children?.includes(state.editorComponent));
  if (index <= 0) return false;
  return (mounted[index - 1]?.children?.length ?? 0) > 1;
};

/**
 * Owns the editor's top border without owning the editor: another extension
 * (spellfix) installs pi's custom editor and only one factory can exist, so this
 * wraps whatever factory is installed. The proxy forwards everything pi wires up
 * (submit, text, keybindings, border color) and intercepts only `render` and
 * `handleMouse`; the border is rewritten after the inner render, so spellfix's
 * styling never reaches it.
 */
export const createEditorChrome = (state: ChromeState, painters: Painters) => {
  let topRegions: Region[] = [];
  let installed: unknown;

  const decorate = (inner: Inner, tui: Renderer) => {
    state.tui = tui;
    state.editor = inner;
    const wrapper: Inner = new Proxy(inner, {
      get(target, property) {
        if (property === "render") {
          return (width: number) => {
            const drawn = target.render(width);
            if (!state.ctx || width <= 0 || drawn.length === 0) return drawn;
            // Resolved per render: pi assigns the border color after the factory
            // returns, and that is the one that tracks thinking level and bash mode.
            const color = target.borderColor;
            const border: Border =
              typeof color === "function" ? color.bind(target) : (text) => text;

            // A widget above the input needs air between it and the border; the
            // border is the editor's first line, so the row goes in front of it.
            const lead = widgetAbove(state) ? 1 : 0;
            const lines = lead === 1 ? ["", ...drawn] : drawn;

            const top = painters.top(width, topHidden(lines[lead] ?? ""), border);
            lines[lead] = top.line;
            topRegions = top.regions;

            // The footer reads this flag to know whether the borders carry the measurements.
            if (!state.metersActive) {
              state.metersActive = true;
              // Repaint after this frame, not inside it.
              setTimeout(() => state.tui?.requestRender(), 0);
            }
            return lines;
          };
        }
        if (property === "handleMouse") {
          return (event: TuiMouseEvent) => {
            // The border sits a row lower while the blank row above it is drawn.
            const borderRow = widgetAbove(state) ? 1 : 0;
            if (event.type === "move") {
              // Leaving the border downward is the only exit pi reports for it.
              state.setHover(event.y === borderRow ? hoverAt(topRegions, event.x) : undefined);
              return target.handleMouse?.(event);
            }
            // Only a control on the top border: the rest keeps pi's behaviour, including
            // click-to-place-cursor in the input.
            const action =
              event.y === borderRow && isPlainClick(event)
                ? hitTest(topRegions, event.x)
                : undefined;
            const ctx = state.ctx;
            if (action && ctx) {
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
    state.editorComponent = wrapper;
    return wrapper;
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
