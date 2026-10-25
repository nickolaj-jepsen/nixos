/**
 * How a feature decorates chrome's prompt editor without the editor knowing
 * about it: each decorator restyles the drawn prompt lines and hears every edit.
 */

/** The prompt draft as a decorator may read and rewrite it. */
export type PromptDraft = {
  getText(): string;
  getLines(): string[];
  getCursor(): { line: number; col: number };
  /** Replaces the whole draft, keeping the pastes its `[paste #n]` markers name. */
  replaceText(text: string): void;
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
  return {
    add: (decorator: EditorDecorator): void => {
      decorators.push(decorator);
    },
    decorateLine: (line: string): string =>
      decorators.reduce((drawn, d) => d.decorateLine?.(drawn) ?? drawn, line),
    edited: (draft: PromptDraft): void => {
      for (const d of decorators) d.onEdit?.(draft);
    },
  };
};

export type EditorHooks = ReturnType<typeof createEditorHooks>;
