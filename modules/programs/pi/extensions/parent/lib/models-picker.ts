/**
 * Whether `/models` holds the screen. The footer's click (chrome/actions.ts)
 * has to tell "the picker is open, so close it" from "another overlay is open,
 * so close that first": opening a second overlay on top of one is how a click
 * stacks two UIs.
 */
let close: (() => void) | undefined;

/** Whether the picker is open. */
export const modelsOpen = (): boolean => close !== undefined;

/** Closes the picker if it is open; it reports back through `setModelsClose`. */
export const closeModels = (): void => {
  close?.();
};

/** The open picker's close, or `undefined` once it has closed. */
export const setModelsClose = (next: (() => void) | undefined): void => {
  close = next;
};
