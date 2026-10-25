/**
 * Whether `/models` holds the screen. The footer's click (chrome/actions.ts)
 * has to tell "the picker is open, so close it" from "another overlay is open,
 * so close that first": opening a second overlay on top of one is how a click
 * stacks two UIs.
 */
export const createModelsPicker = () => {
  let close: (() => void) | undefined;
  return {
    /** Whether the picker is open. */
    isOpen: (): boolean => close !== undefined,
    /** Closes the picker if it is open; it reports back through `setClose`. */
    close: (): void => close?.(),
    /** The open picker's close, or `undefined` once it has closed. */
    setClose: (next: (() => void) | undefined): void => {
      close = next;
    },
  };
};

export type ModelsPicker = ReturnType<typeof createModelsPicker>;
