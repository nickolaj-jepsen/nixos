/**
 * Whether `/models` holds the screen. The footer's click (chrome/actions.ts)
 * has to tell "the picker is open, so close it" from "another overlay is open,
 * so close that first": opening a second overlay on top of one is how a click
 * stacks two UIs.
 *
 * Each extension loads its own copy of a module, so the handle lives on
 * globalThis where both copies see it.
 */
const KEY = Symbol.for("fireproof.pi.models-picker");

type Store = { close?: () => void };

const store: Store = ((globalThis as { [KEY]?: Store })[KEY] ??= {});

/** Whether the picker is open. */
export const modelsOpen = (): boolean => store.close !== undefined;

/** Closes the picker if it is open; it reports back through `setModelsClose`. */
export const closeModels = (): void => {
  store.close?.();
};

/** The open picker's close, or `undefined` once it has closed. */
export const setModelsClose = (close: (() => void) | undefined): void => {
  store.close = close;
};
