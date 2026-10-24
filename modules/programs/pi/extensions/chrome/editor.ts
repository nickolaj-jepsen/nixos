import { matchesKey, type TuiMouseEvent } from "@earendil-works/pi-tui";
import type { EditorWrapper } from "../lib/prompt-editor.ts";
import { hitTest, hoverAt, isPlainClick, type Region } from "./layout.ts";
import type { ChromeState, Renderer } from "./state.ts";

type Border = (text: string) => string;
type Inner = {
  render(width: number): string[];
  handleInput?(data: string): unknown;
  handleMouse?(event: TuiMouseEvent): unknown;
  getText?(): string;
  setText?(text: string): void;
  borderColor?: Border;
  actionHandlers?: Map<string, () => void>;
};

/** What pi shows while it works, retries, compacts or summarises a branch; pi animates it. */
export type BorderStatus = {
  kind: string;
  renderInBorder(width: number): string;
  renderSpinnerInBorder(width: number): string;
};

export type Painters = {
  top: (
    width: number,
    hidden: number,
    border: Border,
    status: BorderStatus | undefined,
  ) => { line: string; regions: Region[] };
  /**
   * The row under the box: `empty` is whether the editor holds anything. The
   * painter owns the content, the wrapper owns inserting it into the editor.
   */
  hint?: (width: number, empty: boolean) => { line: string } | undefined;
  /** The text to insert when that row is accepted, taken at most once. */
  takeHint?: () => string | undefined;
};

const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;
const plain = (line: string) => line.replace(ANSI, "");
const topHidden = (line: string) => Number(/↑\s*(\d+)\s*more/.exec(plain(line))?.[1] ?? 0);

const mounted = (state: ChromeState) => {
  const children = (state.tui as { children?: Array<{ children?: unknown[] }> } | undefined)
    ?.children;
  return Array.isArray(children) ? children : [];
};

/** Which of the TUI's top-level containers holds the wrapped editor; -1 when none does. */
const editorSlot = (state: ChromeState) =>
  state.editorComponent === undefined
    ? -1
    : mounted(state).findIndex((child) => child.children?.includes(state.editorComponent));

/**
 * Whether pi mounted a widget directly above the editor. It puts the
 * above-editor container immediately before the editor's own, seeded with a
 * spacer row, so a widget makes it hold more than that one child. Anything
 * unexpected counts as "no widget": the blank row is spacing, not information,
 * and must not appear on its own.
 */
const widgetAbove = (state: ChromeState): boolean => {
  const index = editorSlot(state);
  if (index <= 0) return false;
  return (mounted(state)[index - 1]?.children?.length ?? 0) > 1;
};

/**
 * Whether the top border is on screen: not before the wrapper is installed,
 * after another factory replaced it, or while pi shows a dialog in its place.
 */
export const borderShown = (state: ChromeState) => editorSlot(state) >= 0;

/**
 * Owns the editor's top border without owning the editor: spellfix supplies it
 * through lib/prompt-editor, and this wraps that instance. The proxy forwards
 * everything pi wires up (submit, text, keybindings, border color) and
 * intercepts only `render`, `handleMouse` and the status pi embeds in the
 * border; the border is rewritten after the inner render, so spellfix's styling
 * never reaches it.
 */
export const createEditorChrome = (state: ChromeState, painters: Painters): EditorWrapper => {
  let topRegions: Region[] = [];
  let status: BorderStatus | undefined;

  const decorate = (inner: Inner, tui: Renderer) => {
    state.tui = tui;
    state.editor = inner;
    const wrapper: Inner = new Proxy(inner, {
      get(target, property) {
        // Kept here rather than passed on, so the inner editor draws the plain
        // border whose `↑ N more` the top reads, and the top places the status.
        if (property === "setWorkingStatusIndicator") {
          return (indicator: BorderStatus | undefined) => {
            status = indicator;
          };
        }
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

            const top = painters.top(width, topHidden(lines[lead] ?? ""), border, status);
            lines[lead] = top.line;
            topRegions = top.regions;
            // The suggestion belongs inside the box, above its bottom border. It
            // only exists while the editor is empty, so the box is exactly one
            // content line and the bottom border sits right behind it.
            const hint = painters.hint?.(width, (target.getText?.() ?? "") === "");
            if (hint) lines.splice(lead + 2, 0, hint.line);
            return lines;
          };
        }
        if (property === "handleInput") {
          return (data: string) => {
            // Tab is pi's autocomplete, but an empty editor has nothing to
            // complete: that keystroke means "use the suggestion" instead.
            if (matchesKey(data, "tab") && (target.getText?.() ?? "") === "") {
              const draft = painters.takeHint?.();
              if (draft !== undefined) {
                target.setText?.(draft);
                return;
              }
            }
            return target.handleInput?.(data);
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
    });
    state.editorComponent = wrapper;
    return wrapper;
  };

  return (inner, host) => decorate(inner as Inner, host[0] as unknown as Renderer) as never;
};
