/**
 * The answer form's contract, shared with pi (parent/lib/answer): find the
 * question round or pick list a turn ended on, step a draft of answers through
 * it, and write the reply a person would have typed. Pure and JSON-safe, so
 * either harness keeps the draft in its own state and only draws it.
 *
 * Parsing is lenient on purpose: the skills' formats are the target, but any
 * agent's numbered questions should parse well enough to answer. A false
 * positive costs a hint the person ignores.
 */

import type { Answer, Draft, Form, Item, Option, Route } from "../types/index.d.ts";

export type { Answer, Draft, Form, Item, Kind, Option, Route } from "../types/index.d.ts";

const FENCE = /^\s*(```|~~~)/;
const RULE = /^\s*(-{3,}|\*{3,}|_{3,})\s*$/;
const HEADING = /^#{1,6}\s/;
// `**Q1. …**`, `### Q2: …`, `1. **…?** …`, `**3.** …`, `Q4) …`; unindented only.
const START = /^(?:#{1,6}\s+)?(\*\*)?(Q)?(\d{1,3})[.:)](?:\*\*)?(?:\s+|$)(.*)$/;
// `- **A.** …`, `- **A. …**`, `A) …`, `**B.** …`.
const OPTION = /^(\s*)(?:[-*+]\s+)?(?:\*\*)?([A-H])[.)](?:\*\*)?\s+(.+)$/;
const RECOMMENDED = /^\s*(?:>\s*)?\**(?:Recommended|(?:My )?recommendation)\**\s*:\s*\**\s*(.*)$/i;
const OWN_RECOMMENDATION = /\((?:my )?recommend(?:ed|ation)\b[^)]*\)/i;
// A letter, then punctuation or the end: "A. The format", "B, because", "**C**"; never "A small".
const LEADING_LETTER = /^(?:option\s+)?\**([A-H])\**(?=$|[\s]*[.,:;)]|\s+[—–-]\s)/i;
const RECOMMEND_IN_TEXT =
  /\b(?:recommend(?:ed)?:?|lean (?:toward|towards))\s+\**(?:option\s+)?([A-H])\b/;
const ROUTES: [RegExp, Route][] = [
  [/\/grill-me\b|\bgrill(?:ing)? (?:it )?first\b/i, "/grill-me"],
  [/\/brainstorm\b|\bbrainstorm(?:ing)? (?:it )?first\b/i, "/brainstorm"],
  [/(?:·|,)\s*build(?: it)?\b|^\s*build(?: it)?\.?\s*$/i, "build"],
];

type Start = { line: number; isQ: boolean; n: number; label: string; title: string; rest: string };

const unbold = (s: string) => s.replace(/\*\*/g, "").trim();

const indentOf = (s: string) => s.length - s.trimStart().length;

/** Title and the rest of a start line, whether the bold wraps the label, the title or nothing. */
function splitTitle(boldLead: boolean, rest: string): [string, string] {
  if (boldLead) {
    const end = rest.indexOf("**");
    return end < 0 ? [rest, ""] : [rest.slice(0, end), rest.slice(end + 2)];
  }
  if (rest.startsWith("**")) {
    const end = rest.indexOf("**", 2);
    if (end > 0) return [rest.slice(2, end), rest.slice(end + 2)];
  }
  return [rest, ""];
}

function findStarts(lines: string[]): Start[] {
  const starts: Start[] = [];
  let inFence = false;
  lines.forEach((line, i) => {
    if (FENCE.test(line)) inFence = !inFence;
    if (inFence) return;
    const m = START.exec(line);
    if (!m) return;
    const [, boldLead, q, n = "", after = ""] = m;
    const [title, rest] = splitTitle(Boolean(boldLead), after);
    if (!unbold(title)) return;
    starts.push({
      line: i,
      isQ: Boolean(q),
      n: Number(n),
      label: q ? `Q${n}` : n,
      title: unbold(title),
      rest: rest.trim(),
    });
  });
  return starts;
}

/**
 * The trailing run of starts: Q-labelled ones when there are any, since
 * numbered lists turn up inside their bodies; a run restarts where the
 * numbering goes back.
 */
function lastRun(starts: Start[]): Start[] {
  const pool = starts.some((s) => s.isQ) ? starts.filter((s) => s.isQ) : starts;
  let run: Start[] = [];
  for (const s of pool) {
    const last = run[run.length - 1];
    if (last && s.n <= last.n) run = [];
    run.push(s);
  }
  return run;
}

/** The lines after a start that belong to it: up to the next start, a rule or a heading. */
function blockOf(lines: string[], start: Start, next: Start | undefined): string[] {
  const end = next ? next.line : lines.length;
  const block: string[] = [];
  let inFence = false;
  for (const line of lines.slice(start.line + 1, end)) {
    if (FENCE.test(line)) inFence = !inFence;
    if (!inFence && (RULE.test(line) || HEADING.test(line))) break;
    block.push(line);
  }
  return block;
}

const tidy = (lines: string[]) =>
  lines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

function parseItem(start: Start, block: string[]): Item {
  const body: string[] = start.rest ? [start.rest] : [];
  const options: Option[] = [];
  let recommended: string | undefined;
  let ownPick: number | undefined;
  let i = 0;
  const following = (keep: (line: string) => boolean) => {
    const taken: string[] = [];
    for (let line = block[i + 1]; line !== undefined && keep(line); line = block[i + 1]) {
      taken.push(line);
      i++;
    }
    return taken;
  };
  for (; i < block.length; i++) {
    const line = block[i] ?? "";
    const rec = RECOMMENDED.exec(line);
    if (rec) {
      // A blockquote recommendation goes on over the quote's following lines.
      const more = line.trimStart().startsWith(">")
        ? following((l) => l.trimStart().startsWith(">")).map((l) => l.trimStart().slice(1).trim())
        : [];
      recommended = unbold([rec[1] ?? "", ...more].filter(Boolean).join(" "));
      continue;
    }
    const opt = OPTION.exec(line);
    const [, lead = "", letter, words = ""] = opt ?? [];
    if (opt && letter === String.fromCharCode(65 + options.length)) {
      const detail = following((l) => Boolean(l.trim()) && indentOf(l) > lead.length).map((l) =>
        l.trim(),
      );
      // `- **A. Title.** More words`: the bold part is the option, the rest its detail.
      const close = words.indexOf("**");
      if (close > 0) detail.unshift(words.slice(close + 2).trim());
      const text = unbold(close > 0 ? words.slice(0, close) : words);
      if (OWN_RECOMMENDATION.test(text)) ownPick = options.length;
      options.push({ key: letter, text, detail: tidy(detail) });
      continue;
    }
    body.push(line);
  }
  // A lone "A." is a sentence, not a choice.
  const choices = options.length >= 2 ? options : [];
  if (choices.length === 0) for (const o of options) body.push(`${o.key}. ${o.text}`, o.detail);
  const bodyText = tidy(body);
  let recommendedOption: number | undefined;
  if (choices.length) {
    const letter =
      (recommended && LEADING_LETTER.exec(recommended)?.[1]) ||
      RECOMMEND_IN_TEXT.exec(bodyText)?.[1];
    const index = letter ? letter.toUpperCase().charCodeAt(0) - 65 : (ownPick ?? -1);
    if (index >= 0 && index < choices.length) recommendedOption = index;
  }
  return {
    label: start.label,
    title: start.title,
    body: bodyText,
    options: choices,
    ...(recommended !== undefined ? { recommended } : {}),
    ...(recommendedOption !== undefined ? { recommendedOption } : {}),
  };
}

export const routeOf = (line: string): Route | undefined =>
  ROUTES.find(([re]) => re.test(line))?.[1];

function parsePicks(lines: string[], run: Start[]): Form | null {
  const items: Item[] = [];
  for (const start of run) {
    const own = [lines[start.line] ?? ""];
    for (const line of lines.slice(start.line + 1)) {
      if (!line.trim() || indentOf(line) < 2) break;
      own.push(line);
    }
    const route = routeOf(own[own.length - 1] ?? "");
    if (!route) return null;
    // `<title> · <size> · <next>` keeps its fields beside the title.
    const [title = "", ...fields] = [start.title, start.rest]
      .filter(Boolean)
      .join(" ")
      .split(" · ");
    const detail = [fields.join(" · "), ...own.slice(1).map((l) => l.trim())].filter(Boolean);
    const options: Option[] = [{ key: "build", text: "Build it", detail: "" }];
    if (route !== "build") options.push({ key: route, text: `Route to ${route}`, detail: "" });
    items.push({
      label: start.label,
      title: unbold(title),
      body: detail.join("\n"),
      options,
      recommended: route === "build" ? "build it" : `route it to ${route}`,
      recommendedOption: route === "build" ? 0 : 1,
    });
  }
  return items.length ? { kind: "picks", items } : null;
}

/** The round or pick list a message ends on, or null when it asks nothing. */
export function parse(text: string): Form | null {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const run = lastRun(findStarts(lines));
  if (!run[0]) return null;
  if (!run[0].isQ) {
    const picks = parsePicks(lines, run);
    if (picks) return picks;
  }
  const items = run.map((s, i) => parseItem(s, blockOf(lines, s, run[i + 1])));
  const endsAsking = text.trimEnd().endsWith("?");
  const asks =
    endsAsking ||
    items.some((it) => it.title.includes("?") || it.recommended !== undefined || it.options.length);
  return asks ? { kind: "round", items } : null;
}

export const newDraft = (form: Form): Draft => ({
  answers: form.items.map(() => null),
  notes: form.items.map(() => ""),
  note: "",
  step: 0,
});

export const canAccept = (item: Item) =>
  item.recommended !== undefined || item.recommendedOption !== undefined;

export const isReview = (form: Form, draft: Draft) => draft.step >= form.items.length;

export const go = (form: Form, draft: Draft, step: number): Draft => ({
  ...draft,
  step: Math.max(0, Math.min(form.items.length, step)),
});

/** A row the form offers for one item: an option, its recommendation when that names no option, or a write-in. */
export type Entry = { kind: "option"; index: number } | { kind: "accept" } | { kind: "write" };

export function entries(item: Item): Entry[] {
  const list: Entry[] = item.options.map((_, index) => ({ kind: "option", index }));
  if (item.recommended !== undefined && item.recommendedOption === undefined)
    list.push({ kind: "accept" });
  list.push({ kind: "write" });
  return list;
}

/** Whether the item's answer is this entry; a write-in is chosen by a text answer. */
export function isChosen(item: Item, a: Answer | null | undefined, entry: Entry): boolean {
  if (!a) return false;
  if (entry.kind === "write") return a.kind === "text";
  if (entry.kind === "accept") return a.kind === "accept";
  return a.kind === "option"
    ? a.index === entry.index
    : a.kind === "accept" && item.recommendedOption === entry.index;
}

/** The entry the cursor starts on: the item's answer, else its recommendation, else the first. */
export function startEntry(item: Item, a: Answer | null | undefined): number {
  const list = entries(item);
  const chosen = list.findIndex((e) => isChosen(item, a, e));
  if (chosen >= 0) return chosen;
  const rec = list.findIndex((e) => isChosen(item, { kind: "accept" }, e));
  return rec >= 0 ? rec : 0;
}

/** Records the shown item's answer and stays on it, so a note can follow. */
export function record(form: Form, draft: Draft, value: Answer): Draft {
  const item = form.items[draft.step];
  if (!item) return draft;
  if (value.kind === "accept" && !canAccept(item)) return draft;
  if (value.kind === "option" && !item.options[value.index]) return draft;
  if (value.kind === "text" && !value.text.trim()) return clear(form, draft);
  const answers = draft.answers.slice();
  answers[draft.step] = value.kind === "text" ? { kind: "text", text: value.text.trim() } : value;
  return { ...draft, answers };
}

/** Answers the shown item and moves on. */
export function answer(form: Form, draft: Draft, value: Answer): Draft {
  const recorded = record(form, draft, value);
  return recorded === draft ? draft : go(form, recorded, draft.step + 1);
}

export function clear(form: Form, draft: Draft): Draft {
  if (isReview(form, draft)) return draft;
  const answers = draft.answers.slice();
  answers[draft.step] = null;
  return { ...draft, answers };
}

/** Leaves the shown item unanswered and moves on. */
export const skip = (form: Form, draft: Draft): Draft =>
  go(form, clear(form, draft), draft.step + 1);

/** The shown item's note, or on the review the whole round's. */
export function setNote(form: Form, draft: Draft, text: string): Draft {
  const note = text.trim();
  if (isReview(form, draft)) return { ...draft, note };
  const notes = draft.notes.slice();
  notes[draft.step] = note;
  return { ...draft, notes };
}

/** True when the answer is the item's recommendation, however it was given. */
const isRecommended = (item: Item, a: Answer | null | undefined) =>
  a?.kind === "accept" || (a?.kind === "option" && a.index === item.recommendedOption);

/** What the reply says for one answer: "yes", a letter or route, or the text. */
export function said(item: Item, a: Answer): string {
  if (a.kind === "text") return a.text;
  const index = a.kind === "option" ? a.index : item.recommendedOption;
  return (index !== undefined && item.options[index]?.key) || "yes";
}

const withNote = (s: string, note: string) => (note ? `${s} — ${note}` : s);

function roundReply(form: Form, draft: Draft): string[] {
  const all = form.items.every((it, i) => isRecommended(it, draft.answers[i]) && !draft.notes[i]);
  if (all && !draft.note) return ["yes"];
  return form.items.flatMap((item, i) => {
    const a = draft.answers[i];
    const note = draft.notes[i] ?? "";
    if (!a) return note ? [`${item.label}: ${note}`] : [];
    const what = a.kind === "accept" ? "yes" : said(item, a);
    return [`${item.label}: ${withNote(what, note)}`];
  });
}

function picksReply(form: Form, draft: Draft): string[] {
  const builds: string[] = [];
  const rest: string[] = [];
  form.items.forEach((item, i) => {
    const a = draft.answers[i];
    const note = draft.notes[i] ?? "";
    const what = a && said(item, a);
    if (!a) {
      if (note) rest.push(`${item.label}: ${note}`);
    } else if (what === "build" && !note) builds.push(item.label);
    else if (what === "build") rest.push(withNote(`do ${item.label}`, note));
    else if (a.kind === "text") rest.push(`${item.label}: ${withNote(a.text, note)}`);
    else rest.push(withNote(`${item.label} → ${what}`, note));
  });
  return [...(builds.length ? [`do ${builds.join(", ")}`] : []), ...rest];
}

/** The reply as the person would type it; "" when nothing was answered. */
export function reply(form: Form, draft: Draft): string {
  const lines = form.kind === "round" ? roundReply(form, draft) : picksReply(form, draft);
  if (draft.note) lines.push(draft.note);
  return lines.join("\n");
}

/** The draft with the reply placed in it: above what the person had typed, never over it. */
export const placeReply = (draft: string, text: string) =>
  draft.trim() ? `${text}\n\n${draft}` : text;
