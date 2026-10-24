/**
 * Lexical recall over a deliberately small store: token overlap, weighted by
 * where the token appears, with a phrase bonus. No embeddings and no persisted
 * index — a few dozen markdown files rebuild in milliseconds.
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

/** Fields searched, with how much a hit in each one counts. */
const FIELDS: { weight: number; of: (entry: Entry) => string }[] = [
  { weight: 3, of: (e) => e.id.replace(/-/g, " ") },
  { weight: 3, of: (e) => e.tags.join(" ") },
  { weight: 2.5, of: (e) => e.statement },
  { weight: 1, of: (e) => e.detail },
  { weight: 1, of: (e) => e.citations.map((c) => c.value).join(" ") },
  { weight: 0.7, of: (e) => e.whyNotDerivable },
];

export type Ranked = { entry: Entry; score: number };

/** Entries matching `query`, best first; an empty query returns nothing. */
export function rank(entries: Entry[], query: string): Ranked[] {
  const tokens = [...new Set(tokenize(query))];
  if (tokens.length === 0) return [];
  const phrase = query.toLowerCase().trim();
  const ranked: Ranked[] = [];
  for (const entry of entries) {
    const fields = FIELDS.map((field) => ({
      weight: field.weight,
      set: tokenSet(field.of(entry)),
    }));
    let score = 0;
    for (const token of tokens) {
      let hit = 0;
      for (const field of fields) if (field.set.has(token)) hit = Math.max(hit, field.weight);
      if (hit > 0) score += hit;
      else if (tokens.length > 1) score -= 0.5; // partial matches rank below complete ones
    }
    if (
      phrase.length > 2 &&
      (entry.statement.toLowerCase().includes(phrase) ||
        entry.id.includes(phrase.replace(/\s+/g, "-")))
    ) {
      score += 4;
    }
    if (score > 0) ranked.push({ entry, score: score + entry.priority / 1000 });
  }
  return ranked.sort((a, b) => b.score - a.score || b.entry.priority - a.entry.priority);
}

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
  const left = tokenSet(`${a.statement} ${a.tags.join(" ")}`);
  const right = tokenSet(`${b.statement} ${b.tags.join(" ")}`);
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
