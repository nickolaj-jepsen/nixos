/**
 * The answer form, with no harness in it: find the question round or pick list a turn ended
 * on, step a draft of answers through it, and write the reply a person would have typed.
 * Pure and JSON-safe, in one file with no imports, so each harness loads it as it stands.
 *
 * Parsing is lenient on purpose: the skills' formats are the target, but any agent's numbered
 * questions should parse well enough to answer. A false positive costs a hint the person ignores.
 */

export type Option = { key: string; text: string; detail: string };

export type FormItem = {
  /** As printed ("Q3", "2"). */
  label: string;
  title: string;
  /** Markdown: what the item said besides its title, options and recommendation. */
  body: string;
  options: Option[];
  recommended?: string;
  recommendedOption?: number;
  recommendedOptions?: number[];
};

export type Form = { kind: "round" | "picks"; items: FormItem[] };

export type Answer =
  | { kind: "option"; index: number }
  | { kind: "options"; indices: number[] }
  | { kind: "accept" }
  | { kind: "text"; text: string };

export type Draft = {
  answers: (Answer | null)[];
  notes: string[];
  /** Said last, about the whole round. */
  note: string;
  /** The item shown, or the item count for the review. */
  step: number;
};

/** One thing a person did at the form (`apply`). */
export type Action =
  | { do: "pick" | "toggle"; entry: number }
  | { do: "write" | "note"; text: string }
  | { do: "go"; step: number }
  | { do: "accept" | "next" | "back" | "forward" | "skip" | "review" };

export type EntryKind = "option" | "accept" | "write";

export type Entry = {
  kind: EntryKind;
  text: string;
  /** The lines that continued it, drawn under it. */
  detail: string;
  isRecommended: boolean;
  isChosen: boolean;
};

export type ItemView = {
  label: string;
  title: string;
  body: string;
  entries: Entry[];
  /** The entry the cursor starts on. */
  start: number;
  /** What it recommends among its options and why, "" with none. */
  recommended: string;
  /** Whether several of its options can be one answer, and whether its answer is several. */
  canSeveral: boolean;
  isSeveral: boolean;
  /** Whether it recommends something a yes can take. */
  canAccept: boolean;
  note: string;
  /** The write-in answer, "" for none. */
  written: string;
};

/** All a surface needs to draw the draft, with no form logic of its own. */
export type View = {
  id: string;
  kind: Form["kind"];
  title: string;
  count: number;
  answered: number;
  step: number;
  isReview: boolean;
  item: ItemView | null;
  review: { label: string; shown: string; isAnswered: boolean; note: string }[];
  note: string;
  reply: string;
};

/** A session's form and the answers so far: what a harness keeps between turns. */
export type Held = { form: Form; draft: Draft };

const FENCE = /^\s*(```|~~~)/;
const RULE = /^\s*(-{3,}|\*{3,}|_{3,})\s*$/;
const HEADING = /^#{1,6}\s/;
// `**Q1. …**`, `### Q2: …`, `1. **…?** …`, `**3.** …`, `Q4) …`; unindented only.
const START = /^(?:#{1,6}\s+)?(\*\*)?(Q)?([0-9]{1,3})[.:)](\*\*)?(?:\s+|$)(.*)$/;
// `- **A.** …`, `- **A. …**`, `A) …`, `**B.** …`.
const OPTION = /^(\s*)(?:[-*+]\s+)?(?:\*\*)?([A-H])[.)](?:\*\*)?\s+(.+)$/;
const RECOMMENDED = /^\s*(?:>\s*)?\**(?:Recommended|(?:My )?recommendation)\**\s*:\s*\**\s*(.*)$/i;
const OWN_RECOMMENDATION = /\((?:(?:my )?recommend(?:ed|ation)|my pick)\b[^)]*\)/i;
// A letter, then punctuation or the end: "A. The format", "B, because", "**C**"; never "A small".
const LEADING_LETTER = /^(?:option\s+)?\**([A-H])\**(?=$|[\s]*[.,:;)]|\s+[—–-]\s)/i;
// Several letters leading a recommendation: "A, B and D now", "A through C", "**A** and **C**."
const LEADING_LETTERS =
  /^\**([A-H])\**((?:\s*(?:,\s*and|,|and|&|\+|through|to|–|-)\s*\**[A-H]\**(?![A-Za-z]))+)/;
const LONE_LETTER = /(?<![A-Za-z])[A-H](?![A-Za-z])/g;
const RANGE = /through|\bto\b|–|-/;
const RECOMMEND_IN_TEXT =
  /\b(?:recommend(?:ed)?:?|lean (?:toward|towards)|(?:I'd|I would) (?:go with|pick))\s+\**(?:option\s+)?([A-H])\b/;
const ROUTES: [RegExp, string][] = [
  [/\/grill-me\b|\bgrill(?:ing)? (?:it )?first\b/i, "/grill-me"],
  [/\/brainstorm\b|\bbrainstorm(?:ing)? (?:it )?first\b/i, "/brainstorm"],
  [/(?:·|,)\s*build(?: it)?\b|^\s*build(?: it)?\.?\s*$/i, "build"],
];

type Start = {
  line: number;
  isQ: boolean;
  n: number;
  label: string;
  title: string;
  rest: string;
};

const unbold = (text: string) => text.replaceAll("**", "").trim();

const indent = (line: string) => line.length - line.trimStart().length;

const tidy = (lines: string[]) =>
  lines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

const letterIndex = (letter: string) => letter.toUpperCase().charCodeAt(0) - 65;

/** Title and the rest of a start line, whether the bold wraps the label, the title or nothing. */
function splitTitle(isBoldLead: boolean, rest: string): [string, string] {
  if (isBoldLead) {
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
    const match = START.exec(line);
    if (!match) return;
    const [, bold, q, n = "", closed, after = ""] = match;
    // `**Q1.** …` closed its bold on the label, so a `**` after it is the title's own.
    const [title, rest] = splitTitle(Boolean(bold) && !closed, after);
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
 * The trailing run of starts: Q-labelled ones when there are any, since numbered lists turn
 * up inside their bodies; a run restarts where the numbering goes back.
 */
function lastRun(starts: Start[]): Start[] {
  const labelled = starts.filter((start) => start.isQ);
  let run: Start[] = [];
  for (const start of labelled.length ? labelled : starts) {
    const last = run[run.length - 1];
    if (last && start.n <= last.n) run = [];
    run.push(start);
  }
  return run;
}

/** The lines after a start that belong to it: up to the next start, a rule or a heading. */
function blockOf(lines: string[], start: Start, following: Start | undefined): string[] {
  const block: string[] = [];
  let inFence = false;
  for (const line of lines.slice(start.line + 1, following ? following.line : lines.length)) {
    if (FENCE.test(line)) inFence = !inFence;
    if (!inFence && (RULE.test(line) || HEADING.test(line))) break;
    block.push(line);
  }
  return block;
}

/** The options a recommendation opens on when it names several, a range read as all of it. */
function leadingLetters(recommended: string, count: number): number[] {
  const match = LEADING_LETTERS.exec(recommended);
  if (!match) return [];
  let letters = (match[0].match(LONE_LETTER) ?? []).map(letterIndex);
  const [first, last] = letters;
  if (
    RANGE.test(match[2] ?? "") &&
    letters.length === 2 &&
    first !== undefined &&
    last !== undefined
  )
    letters = Array.from({ length: Math.max(0, last - first + 1) }, (_, i) => first + i);
  const picked = [...new Set(letters)].sort((a, b) => a - b);
  const highest = picked[picked.length - 1];
  return highest !== undefined && highest < count ? picked : [];
}

function parseItem(start: Start, block: string[]): FormItem {
  const body = start.rest ? [start.rest] : [];
  const options: Option[] = [];
  let recommended: string | undefined;
  let ownPick: number | undefined;
  for (let i = 0; i < block.length; i++) {
    const line = block[i] ?? "";
    const rec = RECOMMENDED.exec(line);
    if (rec) {
      // A blockquote recommendation goes on over the quote's following lines.
      const more: string[] = [];
      if (line.trimStart().startsWith(">"))
        while ((block[i + 1] ?? "").trimStart().startsWith(">")) {
          i++;
          more.push((block[i] ?? "").trimStart().slice(1).trim());
        }
      recommended = unbold([rec[1] ?? "", ...more].filter(Boolean).join(" "));
      continue;
    }
    const opt = OPTION.exec(line);
    if (opt && opt[2] === String.fromCharCode(65 + options.length)) {
      const [, lead = "", letter = "", words = ""] = opt;
      const detail: string[] = [];
      for (
        let next = block[i + 1];
        next?.trim() && indent(next) > lead.length;
        next = block[i + 1]
      ) {
        i++;
        detail.push(next.trim());
      }
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
  if (!choices.length)
    for (const option of options) body.push(`${option.key}. ${option.text}`, option.detail);
  const bodyText = tidy(body);
  const item: FormItem = {
    label: start.label,
    title: start.title,
    body: bodyText,
    options: choices,
  };
  if (recommended !== undefined) item.recommended = recommended;
  if (choices.length) {
    const leading = recommended ? LEADING_LETTER.exec(recommended) : null;
    const letter = (leading ?? RECOMMEND_IN_TEXT.exec(bodyText))?.[1];
    const index = letter ? letterIndex(letter) : (ownPick ?? -1);
    const several = leadingLetters(recommended ?? "", choices.length);
    if (several.length > 1) item.recommendedOptions = several;
    else if (index >= 0 && index < choices.length) item.recommendedOption = index;
  }
  return item;
}

const routeOf = (line: string) => ROUTES.find(([pattern]) => pattern.test(line))?.[1];

function parsePicks(lines: string[], run: Start[]): Form | null {
  const items: FormItem[] = [];
  for (const start of run) {
    const own = [lines[start.line] ?? ""];
    for (const line of lines.slice(start.line + 1)) {
      if (!line.trim() || indent(line) < 2) break;
      own.push(line);
    }
    const route = routeOf(own[own.length - 1] ?? "");
    if (!route) return null;
    // `<title> · <size> · <next>` keeps its fields beside the title.
    const [title = "", ...fields] = [start.title, start.rest]
      .filter(Boolean)
      .join(" ")
      .split(" · ");
    const detail = [fields.join(" · "), ...own.slice(1).map((line) => line.trim())].filter(Boolean);
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
  const first = run[0];
  if (!first) return null;
  if (!first.isQ) {
    const picks = parsePicks(lines, run);
    if (picks) return picks;
  }
  const items = run.map((start, i) => parseItem(start, blockOf(lines, start, run[i + 1])));
  const asks =
    text.trimEnd().endsWith("?") ||
    items.some(
      (item) => item.title.includes("?") || item.recommended !== undefined || item.options.length,
    );
  return asks ? { kind: "round", items } : null;
}

/**
 * The line each item of the form `parse` finds in `text` starts on, so a harness can cut
 * the message into its questions.
 */
export function startLines(text: string): number[] {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  return lastRun(findStarts(lines)).map((start) => start.line);
}

/** JSON with its keys in order, so the same form always reads the same. */
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const fields = Object.entries(value)
      .filter(([, field]) => field !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${fields.map(([key, field]) => `${JSON.stringify(key)}:${canonical(field)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

/** FNV-1a over UTF-16 units from a seed; no harness offers a hash to a module with no imports. */
function fnv(text: string, seed: number): string {
  let hash = seed;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

/**
 * Names a form by what it asks: a turn that asks the same round again keeps its answers, and
 * a step aimed at an older form lands on nothing.
 */
export function formId(form: Form): string {
  const text = canonical(form);
  return fnv(text, 0x811c9dc5) + fnv(text, 0x01234567);
}

export function newDraft(form: Form): Draft {
  const count = form.items.length;
  return {
    answers: Array.from({ length: count }, () => null),
    notes: Array.from({ length: count }, () => ""),
    note: "",
    step: 0,
  };
}

export const isReview = (form: Form, draft: Draft) => draft.step >= form.items.length;

export const go = (form: Form, draft: Draft, step: number): Draft => ({
  ...draft,
  step: Math.max(0, Math.min(form.items.length, step)),
});

const canAccept = (item: FormItem) =>
  item.recommended !== undefined ||
  item.recommendedOption !== undefined ||
  item.recommendedOptions !== undefined;

/** The answer that takes an item's recommendation: its options when it names any, else a yes. */
function accepted(item: FormItem): Answer {
  if (item.recommendedOptions) return { kind: "options", indices: item.recommendedOptions };
  if (item.recommendedOption !== undefined)
    return { kind: "option", index: item.recommendedOption };
  return { kind: "accept" };
}

type Row = { kind: "option"; index: number } | { kind: "accept" } | { kind: "write" };

/**
 * What the form offers for one item: its options, or with none a yes to its recommendation,
 * and a write-in. Beside options a recommendation is only said, never an entry of its own.
 */
export function entries(item: FormItem): Row[] {
  const rows: Row[] = item.options.map((_, index) => ({ kind: "option", index }));
  if (item.recommended !== undefined && !rows.length) rows.push({ kind: "accept" });
  rows.push({ kind: "write" });
  return rows;
}

function isChosen(item: FormItem, answer: Answer | null, entry: Row): boolean {
  if (!answer) return false;
  if (entry.kind === "write") return answer.kind === "text";
  if (entry.kind === "accept") return answer.kind === "accept";
  if (answer.kind === "option") return answer.index === entry.index;
  if (answer.kind === "options") return answer.indices.includes(entry.index);
  return answer.kind === "accept" && item.recommendedOption === entry.index;
}

/** The entry the cursor starts on: the item's answer, else its recommendation, else the first. */
function startEntry(item: FormItem, answer: Answer | null): number {
  const rows = entries(item);
  const chosen = rows.findIndex((entry) => isChosen(item, answer, entry));
  if (chosen >= 0) return chosen;
  return Math.max(
    0,
    rows.findIndex((entry) => isChosen(item, { kind: "accept" }, entry)),
  );
}

const withAnswer = (draft: Draft, value: Answer | null): Draft => ({
  ...draft,
  answers: draft.answers.map((answer, i) => (i === draft.step ? value : answer)),
});

const clear = (form: Form, draft: Draft) =>
  isReview(form, draft) ? draft : withAnswer(draft, null);

/** Records the shown item's answer and stays on it, so a note can follow. */
function record(form: Form, draft: Draft, value: Answer): Draft {
  const item = form.items[draft.step];
  if (!item) return draft;
  if (value.kind === "accept" && !canAccept(item)) return draft;
  if (value.kind === "option" && !(value.index >= 0 && value.index < item.options.length))
    return draft;
  if (value.kind === "options" && !value.indices.length) return clear(form, draft);
  if (value.kind === "text") {
    const text = value.text.trim();
    return text ? withAnswer(draft, { kind: "text", text }) : clear(form, draft);
  }
  return withAnswer(draft, value);
}

const canTakeSeveral = (form: Form, item: FormItem) =>
  form.kind === "round" && item.options.length >= 2;

/** Adds an option to the shown item's answer, or takes it out; a single pick starts the set. */
function toggle(form: Form, draft: Draft, index: number): Draft {
  const item = form.items[draft.step];
  if (!item || !canTakeSeveral(form, item) || !(index >= 0 && index < item.options.length))
    return draft;
  const answer = draft.answers[draft.step];
  const held =
    answer?.kind === "options" ? answer.indices : answer?.kind === "option" ? [answer.index] : [];
  const indices = held.includes(index) ? held.filter((i) => i !== index) : [...held, index];
  return record(form, draft, { kind: "options", indices: indices.sort((a, b) => a - b) });
}

/**
 * After an answer: the next item still unanswered, looking on and then from the top, or the
 * review when every item has one.
 */
function onward(form: Form, draft: Draft): Draft {
  const count = form.items.length;
  const order = [
    ...Array.from({ length: Math.max(0, count - draft.step - 1) }, (_, i) => draft.step + 1 + i),
    ...Array.from({ length: Math.min(draft.step, count) }, (_, i) => i),
  ];
  return go(form, draft, order.find((i) => !draft.answers[i]) ?? count);
}

/** The shown item's note, or on the review the whole round's. */
function setNote(form: Form, draft: Draft, text: string): Draft {
  const note = text.trim();
  if (isReview(form, draft)) return { ...draft, note };
  return { ...draft, notes: draft.notes.map((held, i) => (i === draft.step ? note : held)) };
}

/**
 * The draft after one thing a person did; what can't apply changes nothing.
 *
 * `pick` takes `entry`, an index into the shown item's entries (a write-in has nothing to
 * record until `write`); `toggle` one of several options; `write` records text and goes on;
 * `accept` takes the item's recommendation, whatever it names; `next` goes on to the next item
 * unanswered. Throws for a word it doesn't know.
 */
export function apply(form: Form, draft: Draft, action: Action): Draft {
  const { step } = draft;
  const item = form.items[step];
  switch (action.do) {
    case "pick":
    case "toggle": {
      const row = item ? entries(item)[action.entry] : undefined;
      if (!row || row.kind === "write") return draft;
      if (action.do === "pick") return record(form, draft, row);
      return row.kind === "option" ? toggle(form, draft, row.index) : draft;
    }
    case "write": {
      const written = record(form, draft, { kind: "text", text: action.text ?? "" });
      return written.answers[step] ? onward(form, written) : written;
    }
    case "note":
      return setNote(form, draft, action.text ?? "");
    case "accept":
      return item && canAccept(item) ? record(form, draft, accepted(item)) : draft;
    case "next":
      return isReview(form, draft) ? draft : onward(form, draft);
    case "go":
      return go(form, draft, action.step ?? step);
    case "back":
      return go(form, draft, step - 1);
    case "forward":
      return go(form, draft, step + 1);
    case "skip":
      return go(form, clear(form, draft), step + 1);
    case "review":
      return go(form, draft, form.items.length);
    default:
      throw new Error(`no such action: ${JSON.stringify((action as { do?: unknown }).do)}`);
  }
}

const isSame = (a: number[], b: (number | undefined)[]) =>
  a.length === b.length && a.every((value, i) => value === b[i]);

function isRecommended(item: FormItem, answer: Answer | null): boolean {
  if (!answer) return false;
  if (answer.kind === "options")
    return isSame(answer.indices, item.recommendedOptions ?? [item.recommendedOption]);
  return (
    answer.kind === "accept" ||
    (answer.kind === "option" && answer.index === item.recommendedOption)
  );
}

const keyAt = (item: FormItem, index: number) => item.options[index]?.key ?? "";

/** What the reply says for one answer: "yes", a letter or several, a route, or the text. */
function said(item: FormItem, answer: Answer): string {
  if (answer.kind === "text") return answer.text;
  if (answer.kind === "options")
    return answer.indices.map((index) => keyAt(item, index)).join(", ");
  const index = answer.kind === "option" ? answer.index : item.recommendedOption;
  return index === undefined ? "yes" : keyAt(item, index);
}

const NO_ANSWER = "no answer yet";

/** A reply line and, under it, the note it carries. */
const noted = (line: string, note: string) => (note ? [line, `    Note: ${note}`] : [line]);

const rowsOf = (form: Form, draft: Draft) =>
  form.items.map((item, i) => ({
    item,
    answer: draft.answers[i] ?? null,
    note: draft.notes[i] ?? "",
  }));

function roundReply(form: Form, draft: Draft): string[] {
  const rows = rowsOf(form, draft);
  if (rows.every(({ item, answer, note }) => isRecommended(item, answer) && !note) && !draft.note)
    return ["yes"];
  return rows.flatMap(({ item, answer, note }) => {
    if (answer)
      return noted(`${item.label}: ${answer.kind === "accept" ? "yes" : said(item, answer)}`, note);
    return note ? noted(`${item.label}: ${NO_ANSWER}`, note) : [];
  });
}

function picksReply(form: Form, draft: Draft): string[] {
  const builds: string[] = [];
  const rest: string[] = [];
  for (const { item, answer, note } of rowsOf(form, draft)) {
    const { label } = item;
    if (!answer) {
      if (note) rest.push(...noted(`${label}: ${NO_ANSWER}`, note));
      continue;
    }
    const what = said(item, answer);
    if (what === "build" && !note) builds.push(label);
    else if (what === "build") rest.push(...noted(`do ${label}`, note));
    else if (answer.kind === "text") rest.push(...noted(`${label}: ${answer.text}`, note));
    else rest.push(...noted(`${label} → ${what}`, note));
  }
  return [...(builds.length ? [`do ${builds.join(", ")}`] : []), ...rest];
}

/** The reply as the person would type it; "" when nothing was answered. */
export function reply(form: Form, draft: Draft): string {
  const lines = form.kind === "round" ? roundReply(form, draft) : picksReply(form, draft);
  if (draft.note) lines.push(`Overall: ${draft.note}`);
  return lines.join("\n");
}

function entryText(form: Form, item: FormItem, entry: Row): string {
  if (entry.kind === "write")
    return form.kind === "round" ? "Write your own answer" : "Something else";
  if (entry.kind === "accept") return `Yes: ${item.recommended || "as recommended"}`;
  const option = item.options[entry.index];
  if (!option) return "";
  return form.kind === "round" ? `${option.key}. ${option.text}` : option.text;
}

const textAt = (item: FormItem, index: number) => item.options[index]?.text ?? "";

/** What an answer reads as on the review: the option's words, not just its key. */
function shown(item: FormItem, answer: Answer | null): string {
  if (!answer) return "skipped";
  if (answer.kind === "text") return `"${answer.text}"`;
  if (answer.kind === "options")
    return `${said(item, answer)}: ${answer.indices.map((index) => textAt(item, index)).join("; ")}`;
  const index = answer.kind === "option" ? answer.index : item.recommendedOption;
  return index === undefined ? "yes" : `${said(item, answer)}: ${textAt(item, index)}`;
}

export function title(form: Form): string {
  const count = form.items.length;
  const plural = count === 1 ? "" : "s";
  return form.kind === "round"
    ? `Answer ${count} question${plural}`
    : `Pick from ${count} item${plural}`;
}

function itemView(form: Form, draft: Draft): ItemView | null {
  const item = form.items[draft.step];
  if (!item) return null;
  const answer = draft.answers[draft.step] ?? null;
  const recommended = item.recommendedOptions ?? [item.recommendedOption];
  return {
    label: item.label,
    title: item.title,
    body: item.body,
    entries: entries(item).map((entry) => ({
      kind: entry.kind,
      text: entryText(form, item, entry),
      detail: entry.kind === "option" ? (item.options[entry.index]?.detail ?? "") : "",
      isRecommended: entry.kind === "option" && recommended.includes(entry.index),
      isChosen: isChosen(item, answer, entry),
    })),
    start: startEntry(item, answer),
    // What it recommends among its options and why; with no options that is the accept entry.
    recommended: item.options.length ? (item.recommended ?? "") : "",
    canSeveral: canTakeSeveral(form, item),
    // Its answer is several, or with none yet its recommendation is.
    isSeveral: answer ? answer.kind === "options" : item.recommendedOptions !== undefined,
    canAccept: canAccept(item),
    note: draft.notes[draft.step] ?? "",
    written: answer?.kind === "text" ? answer.text : "",
  };
}

export function view(form: Form, draft: Draft): View {
  return {
    id: formId(form),
    kind: form.kind,
    title: title(form),
    count: form.items.length,
    answered: draft.answers.filter(Boolean).length,
    step: draft.step,
    isReview: isReview(form, draft),
    item: itemView(form, draft),
    review: rowsOf(form, draft).map(({ item, answer, note }) => ({
      label: item.label,
      shown: shown(item, answer),
      isAnswered: Boolean(answer),
      note,
    })),
    note: draft.note,
    reply: reply(form, draft),
  };
}

/**
 * A turn ended on `text`. A new round replaces what was held and the same one keeps its
 * answers; a turn that asks nothing leaves it, since a turn a background task woke ends on
 * that task's news while the round still waits.
 */
export function offer(held: Held | null, text: string): Held | null {
  const form = parse(text);
  if (!form || (held && formId(held.form) === formId(form))) return held;
  return { form, draft: newDraft(form) };
}

/** One action on what is held, when `id` (if given) still names the form showing. */
export function step(held: Held, action: Action, id?: string): Held {
  if (id !== undefined && id !== formId(held.form)) return held;
  const draft = apply(held.form, held.draft, action);
  return draft === held.draft ? held : { ...held, draft };
}

export const viewOf = (held: Held | null): View | null =>
  held ? view(held.form, held.draft) : null;
