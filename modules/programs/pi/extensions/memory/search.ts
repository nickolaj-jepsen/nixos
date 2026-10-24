/**
 * Lexical overlap for the save gate and review: token sets over a deliberately
 * small store. No embeddings and no persisted index.
 */
import type { Entry } from "./store.ts";

const STOPWORDS = new Set(
  "a an and are as at be been but by can could did do does for from had has have how i if in into is it its just me my no not of on or our so than that the their them then there these they this to too us was we were what when where which who why will with would you your".split(
    " ",
  ),
);

/** Lowercased word tokens, stopwords dropped, a trailing plural `s` folded. */
export function tokenize(text: string): string[] {
  const out: string[] = [];
  for (const raw of text.toLowerCase().split(/[^a-z0-9]+/)) {
    if (raw.length < 2 || STOPWORDS.has(raw)) continue;
    out.push(raw.length > 3 && raw.endsWith("s") && !raw.endsWith("ss") ? raw.slice(0, -1) : raw);
  }
  return out;
}

export const tokenSet = (text: string) => new Set(tokenize(text));

/** Jaccard overlap of two token sets. */
export function overlap(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let shared = 0;
  for (const token of a) if (b.has(token)) shared++;
  return shared / (a.size + b.size - shared);
}

/** Share of `a`'s tokens that `b` also has, 0-1; unlike Jaccard, a long `b` is not punished. */
export function containment(a: Set<string>, b: Set<string>): number {
  if (a.size === 0) return 0;
  let shared = 0;
  for (const token of a) if (b.has(token)) shared++;
  return shared / a.size;
}

/** Whether two entries say substantially the same thing. */
export function nearDuplicate(a: Entry, b: Entry): boolean {
  if (a.id === b.id) return true;
  const left = tokenSet(a.statement);
  const right = tokenSet(b.statement);
  return (
    overlap(left, right) >= 0.6 ||
    containment(left, right) >= 0.9 ||
    containment(right, left) >= 0.9
  );
}

/** How much of `statement` already appears in `text` (for context-file dedupe). */
export function coveredBy(statement: string, text: string): boolean {
  const mine = tokenSet(statement);
  if (mine.size < 3) return false;
  return containment(mine, tokenSet(text)) >= 0.85;
}
