/**
 * Spellfix's logic that needs no engine: which words to check, the model's
 * prompt and reply, where its extras land, and the fix log and personal
 * dictionary formats. Plain ES with no Node or engine API, so pi's spellfix
 * can run the same rules on the files both agents write.
 */
import type { Extra, FixLog, FixSource, Miss } from "../types";

export type Verdict = { kind: "fix"; word: string } | { kind: "correct" } | { kind: "unsure" };

/** A typo the model named by word and occurrence, before it is placed in the draft. */
export type Found = { word: string; nth: number; fix: string };

export type LogPick = { from: string; to: string; as: FixSource | "rejected" };

export const CHECK = `You check spelling in a draft message a developer is about to send to a coding assistant. The draft may be in English or Danish, or mix both; never translate.

A spell checker flagged the words marked ⟦like this⟧. Give each distinct flagged word one line:
<word text="teh" verdict="fix">the</word> when it is a typo: the word they meant, in the same language and casing.
<word text="Jepsen" verdict="correct"/> when it is a real word, name, product or technical term spelled as intended.
<word text="xqzt" verdict="unsure"/> when you can't tell.

Then give one line per typo outside the marked words, which the spell checker can't see: a word joined to another by a slash ("dense/recieve"), or a correctly spelled word that is clearly not the one meant ("form" for "from"). "word" is the typo exactly as written in the draft, and nth counts that word's occurrences in the draft from 1:
<extra word="recieve" nth="1">receive</extra>

Rules:
- Spelling only: never grammar, style, punctuation or wording.
- Never touch code, file paths, URLs, identifiers, command names, flags, @mentions, /slash-commands, or anything inside backticks.
- Reply with these lines and nothing else.`;

const SKIPPED_SCRIPTS =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]/u;
const WORD = /^\p{L}+(?:['’]\p{L}+)*$/u;

/** hunspell's arguments after the executable: `-l` lists rejected words, `-a` is pipe mode. */
export function hunspellArgs(mode: "-l" | "-a", dictionaries: string, personal: string): string[] {
  return [mode, "-d", dictionaries, ...(personal ? ["-p", personal] : [])];
}

/** `text` with code blocks and spans blanked out, offsets kept. */
export function maskCode(text: string): string {
  return text.replace(/```[\s\S]*?(?:```|$)|`[^`\n]*`?/g, (m) => " ".repeat(m.length));
}

/** The words to check, by the built-in spellcheck's documented rules: code-like text is left out. */
export function candidates(text: string): Miss[] {
  const out: Miss[] = [];
  for (const tok of maskCode(text).matchAll(/\S+/g)) {
    // Commands, mentions, flags, URLs, paths, and anything with digits or underscores.
    if (/^[/@-]|[/\\_~\d]|:\/\/|\.\p{L}/u.test(tok[0])) continue;
    for (const m of tok[0].matchAll(/\p{L}+(?:['’]\p{L}+)*/gu)) {
      const word = m[0];
      if (word.length < 2 || /.\p{Lu}/u.test(word) || SKIPPED_SCRIPTS.test(word)) continue;
      const start = tok.index + m.index;
      out.push({ word, start, end: start + word.length });
    }
  }
  return out;
}

/** hunspell `-a` input asking for `word`'s suggestions; `^` keeps the word from being read as a command. */
export function suggestInput(word: string): string {
  return `^${word}\n`;
}

/** The first `limit` suggestions in hunspell `-a` output; none when the word was accepted. */
export function parseSuggestions(stdout: string, limit: number): string[] {
  const line = stdout.split("\n").find((l) => l.startsWith("& "));
  return line?.split(": ")[1]?.split(", ").filter(Boolean).slice(0, limit) ?? [];
}

/** hunspell `-a` input adding `words` to the personal dictionary (`*`) and saving it (`#`). */
export function addInput(words: readonly string[]): string {
  return `${words.map((w) => `*${w}\n`).join("")}#\n`;
}

/** The personal dictionary `text` without `words`; hunspell itself can't remove one. */
export function withoutWords(text: string, words: readonly string[]): string {
  // A line may carry affix flags after a slash (`word/S`).
  return text
    .split("\n")
    .filter((l) => !words.includes(l.split("/")[0]!))
    .join("\n");
}

/** The words `verdicts` calls correct, for the personal dictionary, minus those `skip` holds back. */
export function autoAdds(
  verdicts: ReadonlyMap<string, Verdict>,
  skip: (word: string) => boolean,
): string[] {
  return [...verdicts].filter(([word, v]) => v.kind === "correct" && !skip(word)).map(([w]) => w);
}

/** `text` with every flagged word wrapped for the model, as CHECK describes. */
export function mark(text: string, flagged: readonly Miss[]): string {
  let marked = text;
  for (const m of [...flagged].sort((a, b) => b.start - a.start)) {
    marked = `${marked.slice(0, m.start)}⟦${m.word}⟧${marked.slice(m.end)}`;
  }
  return marked;
}

/** The user message for CHECK. */
export function checkPrompt(text: string, flagged: readonly Miss[]): string {
  return `<draft>\n${mark(text, flagged)}\n</draft>`;
}

/** Enough output tokens for a line per distinct flagged word plus a few extras. */
export function replyBudget(distinct: number): number {
  return Math.min(4096, 48 * (distinct + 10));
}

/**
 * A reply to CHECK for `text`: a verdict per flagged word in `distinct` and the
 * typos it found outside them, still by word and occurrence.
 */
export function parseReply(
  reply: string,
  text: string,
  distinct: ReadonlySet<string>,
): { verdicts: Map<string, Verdict>; found: Found[] } {
  const verdicts = new Map<string, Verdict>();
  const found: Found[] = [];
  for (const m of reply.matchAll(
    /<word text="([^"]+)" verdict="(fix|correct|unsure)"\s*(?:\/>|>([^<]*)<\/word>)/g,
  )) {
    const [, word = "", kind, fix = ""] = m;
    // The model sometimes answers an extra as a verdict; taken as one when the draft has it once.
    if (!distinct.has(word)) {
      if (kind === "fix" && locate(text, word, 2) === undefined) found.push({ word, nth: 1, fix });
      continue;
    }
    // A "fix" back to the same word says nothing either way.
    const isFix = kind === "fix" && fix.trim() !== "" && fix.trim() !== word;
    verdicts.set(
      word,
      isFix
        ? { kind: "fix", word: fix.trim() }
        : kind === "correct"
          ? { kind }
          : { kind: "unsure" },
    );
  }
  for (const m of reply.matchAll(/<extra word="([^"]+)" nth="(\d+)">([^<]+)<\/extra>/g)) {
    const [, word = "", nth = "", fix = ""] = m;
    found.push({ word, nth: Number(nth), fix });
  }
  return { verdicts, found };
}

/**
 * `word`'s nth whole-word occurrence in `text`, counting code too, as the model
 * does; undefined when that lands in code, a URL, a command, a mention or a
 * flag. Unlike `candidates`, a word in a slashed token (`dense/consice`) counts.
 */
export function locate(text: string, word: string, nth: number): Miss | undefined {
  if (!WORD.test(word) || nth < 1) return undefined;
  const at = [...text.matchAll(new RegExp(`(?<![\\p{L}'’])${word}(?![\\p{L}'’])`, "gu"))][nth - 1];
  if (at === undefined) return undefined;
  const end = at.index + word.length;
  const tok = [...maskCode(text).matchAll(/\S+/g)].find(
    (t) => t.index <= at.index && end <= t.index + t[0].length,
  );
  if (!tok || /^[/@-]|:\/\//.test(tok[0])) return undefined;
  return { word, start: at.index, end };
}

/**
 * `found` placed in `text`, the draft the model saw: one extra per offset, none
 * on a flagged word, and none that would leave the word as it is.
 */
export function placeExtras(
  text: string,
  found: readonly Found[],
  flagged: readonly Miss[],
): Extra[] {
  const extras: Extra[] = [];
  for (const { word, nth, fix } of found) {
    const at = locate(text, word, nth);
    if (!at || fix.trim() === word || flagged.some((f) => f.start === at.start)) continue;
    if (!extras.some((x) => x.start === at.start)) extras.push({ ...at, fix: fix.trim() });
  }
  return extras;
}

/** `m` past an edit that replaced start..end with `delta` more characters; undefined when the edit touched it. */
export function shift<T extends Miss>(
  m: T,
  start: number,
  end: number,
  delta: number,
): T | undefined {
  if (m.end <= start) return m;
  if (m.start >= end) return { ...m, start: m.start + delta, end: m.end + delta };
  return undefined;
}

export function isExtra(m: Miss | Extra): m is Extra {
  return "fix" in m;
}

/** `misses` with the `extras` that overlap none of them, in draft order. */
export function withExtras(misses: readonly Miss[], extras: readonly Extra[]): (Miss | Extra)[] {
  const found: (Miss | Extra)[] = [...misses];
  for (const x of extras) {
    if (!found.some((m) => m.start < x.end && x.start < m.end)) found.push(x);
  }
  return found.sort((a, b) => a.start - b.start);
}

export function nearest<T extends Miss>(found: readonly T[], cursor: number): T | undefined {
  const distance = (m: Miss) => (cursor < m.start ? m.start - cursor : Math.max(0, cursor - m.end));
  return found.reduce<T | undefined>(
    (best, m) => (!best || distance(m) < distance(best) ? m : best),
    undefined,
  );
}

/** `log` with `picks` counted, each dated `last` (YYYY-MM-DD). */
export function countPicks(log: FixLog, picks: readonly LogPick[], last: string): FixLog {
  for (const { from, to, as } of picks) {
    const counts = ((log[from] ??= {})[to] ??= { last });
    counts[as] = (counts[as] ?? 0) + 1;
    counts.last = last;
  }
  return log;
}

/** The fix log file's text for `log`. */
export function formatLog(log: FixLog): string {
  return `${JSON.stringify(log, null, 1)}\n`;
}

/** The fix picked most for `word`, net of the model's rejected ones; null when none comes out ahead. */
export function topFix(log: FixLog | undefined, word: string): string | null {
  let best: string | null = null;
  let bestScore = 0;
  for (const [to, c] of Object.entries(log?.[word] ?? {})) {
    const score = (c.haiku ?? 0) + (c.hunspell ?? 0) + (c.history ?? 0) - (c.rejected ?? 0);
    if (score > bestScore) [best, bestScore] = [to, score];
  }
  return best;
}
