/**
 * How a feature decorates chrome's prompt editor without the editor knowing
 * about it: each decorator restyles the drawn prompt lines and hears every edit.
 *
 * A feature of another package (spellfix's pi half, from agents) can't import
 * this, so the hooks are offered on pi's event bus as well: a listener hears the
 * offer, or asks for one at session start, and decorates the editor it is
 * handed. That plugin restates these channels and the shape in `pi/editor.ts`.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** The prompt draft as a decorator may read and rewrite it. */
export type PromptDraft = {
  getText(): string;
  getLines(): string[];
  getCursor(): { line: number; col: number };
  /** Replaces the whole draft, keeping the pastes its `[paste #n]` markers name. */
  replaceText(text: string): void;
  /** Adds a prompt to the up-arrow history, as a submitted one would be. */
  addToHistory(text: string): void;
  requestRender(): void;
};

export type EditorDecorator = {
  /** One drawn line of prompt text (never the border), with the editor's own escapes in it. */
  decorateLine?(line: string): string;
  /** The draft changed, by a keystroke, a paste or a `setText`. */
  onEdit?(draft: PromptDraft): void;
};

export const createEditorHooks = () => {
  const decorators: EditorDecorator[] = [];
  let current: PromptDraft | undefined;
  return {
    add: (decorator: EditorDecorator): void => {
      decorators.push(decorator);
    },
    attach: (draft: PromptDraft): void => {
      current = draft;
    },
    /** The editor on screen now; pi builds a fresh one for every session. */
    current: (): PromptDraft | undefined => current,
    decorateLine: (line: string): string =>
      decorators.reduce((drawn, d) => d.decorateLine?.(drawn) ?? drawn, line),
    edited: (draft: PromptDraft): void => {
      for (const d of decorators) d.onEdit?.(draft);
    },
  };
};

export type EditorHooks = ReturnType<typeof createEditorHooks>;

/** Carries the bridge; a listener is handed the publisher's own object. */
export const EDITOR_HOOKS_OFFER = "fireproof:editor-hooks:offer";
/** Emitted at session start by a listener that may have missed the offer. */
export const EDITOR_HOOKS_REQUEST = "fireproof:editor-hooks:request";

/** What another package may use of the editor. */
export type EditorBridge = Pick<EditorHooks, "add" | "current">;

/**
 * Offers the editor's hooks to the other packages, and again whenever one asks:
 * packages load in an order neither side controls, and an offer a listener was
 * not yet there for would otherwise leave it without the underlines.
 */
export const publishEditorHooks = (pi: ExtensionAPI, hooks: EditorHooks): void => {
  const bridge: EditorBridge = { add: hooks.add, current: hooks.current };
  pi.events.on(EDITOR_HOOKS_REQUEST, () => pi.events.emit(EDITOR_HOOKS_OFFER, bridge));
  pi.on("session_start", () => pi.events.emit(EDITOR_HOOKS_OFFER, bridge));
};
