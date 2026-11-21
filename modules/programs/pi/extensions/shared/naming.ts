/** Small text helpers shared by the extensions. */
/** `text` on one line, whitespace collapsed. */
export const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** `text` cut to `max` characters, the last one an ellipsis. */
export const clip = (text: string, max: number) =>
  text.length > max ? `${text.slice(0, max - 1)}…` : text;
