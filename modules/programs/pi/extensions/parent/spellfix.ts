/**
 * Spelling fixes for the prompt draft, on the Claude Code spellfix mod's core
 * (modules/programs/claude-code/mods/spellfix). hunspell flags the words; one
 * model call answers every flagged word at once and finds real-word typos
 * hunspell cannot see (`form` for `from`).
 *
 * - Misspelled words are underlined in the editor while you type.
 * - ctrl+q (or /spellfix) opens the draft as a review: one row per decision,
 *   each the word struck out and its replacement in green. `space` toggles a
 *   row, `a` writes the checked ones into the editor and closes, `enter` applies
 *   just the focused one, `d` keeps a word by adding it to the personal
 *   dictionary, `u` takes back the words this answer added, esc changes nothing.
 *   `/spellfix undo` takes the last answer's adds back once the review is closed.
 *
 * Shares the personal dictionary with the Claude Code mod, so a word learned in
 * one is known to the other; the core keeps their rules and file format the same.
 */
import { spawn } from "node:child_process";
import { mkdir, open, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import type {
  ExtensionAPI,
  ExtensionContext,
  ExtensionUIContext,
  Theme,
} from "@earendil-works/pi-coding-agent";
import { Key, matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { Component, TUI } from "@earendil-works/pi-tui";

import {
  addInput,
  applyEdits,
  autoAdds,
  candidates,
  caseVariants,
  CHECK,
  checkPrompt,
  hunspellArgs,
  parseReply,
  placeExtras,
  recase,
  replyBudget,
  shift,
  wordDiff,
  withExtras,
  withoutWords,
} from "./lib/spellfix/hooks/core.ts";
import type { Found, Splice, Verdict } from "./lib/spellfix/hooks/core.ts";
import type { Extra, Miss } from "./lib/spellfix/types/index.d.ts";
import { sideCall } from "../shared/side-call.ts";
import type { PromptDraft } from "./lib/editor-hooks.ts";
import type { Services } from "./services.ts";

const HUNSPELL = process.env.PI_SPELLFIX_HUNSPELL || "hunspell";
const DICTIONARIES = process.env.PI_SPELLFIX_DICTS || "en_US";
const PERSONAL = process.env.PI_SPELLFIX_PERSONAL || "";
// Not vm/flash: its endpoint spends seconds on reasoning for this prompt, and
// the review waits on the call. Haiku answers every word in about a second.
const MODEL = "anthropic/claude-haiku-5-5";

const CHECK_DELAY_MS = 300;
/** Lines one finding takes in the review: its kind, then the draft with the fix in place. */
const FINDING_LINES = 2;
/** Frame lines around the findings: two borders, the header's blank line, the hints. */
const CHROME_LINES = 6;
const MAX_FINDINGS = 9;
const CONTEXT = 28;

const WORD_IN_TEXT = /[\p{L}]+(?:['’][\p{L}]+)*/gu;
// SGR and APC, the only escapes the editor draws with. Text between them is
// safe to style without corrupting a sequence.
const ESCAPE = /\x1b\[[0-9;:?]*[ -/]*[@-~]|\x1b_[^\x07]*\x07/g;

/** One decision in the review: the same replacement at one or more places in the draft. */
type Finding = {
  /** The draft text this replaces. */
  word: string;
  /** What it becomes; null while the model is still thinking or cannot tell. */
  fix: string | null;
  kind: "typo" | "casing" | "real word" | "unsure";
  /** Every occurrence this answer applies to, in draft order. */
  offsets: Miss[];
  checked: boolean;
};

/** Set at load; the batch call's spend is recorded through it. */
let api: ExtensionAPI | undefined;
/** Words skipped in the review, forgotten once the draft is submitted or cleared. */
const ignored = new Set<string>();
// Auto-added words taken back with `u`; the model's "correct" leaves them flagged for this draft.
const unadded = new Set<string>();
/** What the last answer added to the personal dictionary, for `/spellfix undo`. */
let lastAdded: string[] = [];

/** The live TUI session; the editor's hooks act only while there is one. */
let live: ExtensionContext | undefined;
/** The prompt editor that reported the latest edit. */
let editor: PromptDraft | undefined;
/** Its text at that edit: a cursor move reports an edit too, and needs no check. */
let editedText: string | undefined;
/** The words the editor underlines: by word, not offset, so every occurrence is marked. */
let underlined: ReadonlySet<string> = new Set();
let timer: ReturnType<typeof setTimeout> | undefined;
let checkId = 0;
/**
 * Bumped on session start and shutdown: a ctx captured before the bump is unusable,
 * so anything holding one across an await checks its gen first.
 */
let sessionGen = 0;
let suspended = false;
let warnedHunspell = false;

/**
 * The last model answer, kept for reopening the review on the same draft
 * without paying for it again; `text` follows the review's own fixes.
 */
let batch: { text: string; verdicts: Map<string, Verdict>; extras: Extra[] } | undefined;

function toast(
  ctx: ExtensionContext,
  message: string,
  level: "info" | "warning" | "error" = "info",
) {
  ctx.ui.notify(message, level);
}

function warnHunspell(ctx: ExtensionContext, error: unknown) {
  if (warnedHunspell) return;
  warnedHunspell = true;
  toast(
    ctx,
    `spellfix: hunspell failed: ${error instanceof Error ? error.message : String(error)}`,
    "error",
  );
}

function ensurePersonal(): Promise<void> {
  if (!PERSONAL) return Promise.resolve();
  return mkdir(dirname(PERSONAL), { recursive: true })
    .then(() => open(PERSONAL, "a"))
    .then((file) => file.close())
    .catch(() => undefined);
}

async function runHunspell(
  gen: number,
  ctx: ExtensionContext,
  mode: "-l" | "-a",
  stdin: string,
): Promise<string | undefined> {
  try {
    return await new Promise<string>((resolve, reject) => {
      const child = spawn(HUNSPELL, hunspellArgs(mode, DICTIONARIES, PERSONAL), {
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      let settled = false;
      const finish = (fn: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        fn();
      };
      const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
      child.stdout.on("data", (data: Buffer) => (stdout += data.toString()));
      child.stderr.on("data", (data: Buffer) => (stderr += data.toString()));
      child.on("error", (error) => finish(() => reject(error)));
      child.on("close", (code) =>
        finish(() =>
          code === 0 ? resolve(stdout) : reject(new Error(stderr.trim() || `exit ${code}`)),
        ),
      );
      child.stdin.on("error", () => undefined);
      child.stdin.end(stdin);
    });
  } catch (error) {
    // hunspell can fail after the session its ctx belongs to is gone.
    if (gen === sessionGen) warnHunspell(ctx, error);
    return undefined;
  }
}

/** The candidates hunspell rejects, skipped words excluded; none when hunspell fails. */
async function findMisses(gen: number, ctx: ExtensionContext, text: string): Promise<Miss[]> {
  const words = candidates(text).filter((w) => !ignored.has(w.word));
  if (words.length === 0) return [];
  const stdout = await runHunspell(
    gen,
    ctx,
    "-l",
    `${[...new Set(words.map((w) => w.word))].join("\n")}\n`,
  );
  if (stdout === undefined) return [];
  const bad = new Set(stdout.split("\n").filter(Boolean));
  return words.filter((w) => bad.has(w.word));
}

/** The words of `words` hunspell accepts; none when it fails. */
async function knownWords(
  gen: number,
  ctx: ExtensionContext,
  words: readonly string[],
): Promise<Set<string>> {
  if (words.length === 0) return new Set();
  const stdout = await runHunspell(gen, ctx, "-l", `${words.join("\n")}\n`);
  if (stdout === undefined) return new Set();
  const bad = new Set(stdout.split("\n"));
  return new Set(words.filter((w) => !bad.has(w)));
}

/** Replaces `path` with `text` by renaming a temporary file over it, so no reader sees it half-written. */
async function writeAtomic(path: string, text: string) {
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, text);
  await rename(tmp, path);
}

async function addWords(gen: number, ctx: ExtensionContext, words: readonly string[]) {
  for (const word of words) ignored.add(word);
  lastAdded = [...new Set([...lastAdded, ...words])];
  if (!PERSONAL || words.length === 0) return;
  await ensurePersonal();
  await runHunspell(gen, ctx, "-a", addInput(words));
}

/** Takes auto-added words back out of the personal dictionary; hunspell itself cannot remove one. */
async function removeWords(gen: number, ctx: ExtensionContext, words: readonly string[]) {
  for (const word of words) {
    ignored.delete(word);
    unadded.add(word);
  }
  if (!PERSONAL) return;
  try {
    await writeAtomic(PERSONAL, withoutWords(await readFile(PERSONAL, "utf8"), words));
  } catch (error) {
    if (gen === sessionGen)
      toast(ctx, `spellfix: couldn't edit ${PERSONAL}: ${String(error)}`, "error");
  }
}

type Answer = { verdicts: Map<string, Verdict>; found: Found[] };

async function askModel(
  gen: number,
  ctx: ExtensionContext,
  text: string,
  flagged: readonly Miss[],
  signal: AbortSignal,
): Promise<Answer | undefined> {
  if (!api) return undefined;
  const distinct = new Set(flagged.map((m) => m.word));
  const reply = await sideCall(api, ctx, {
    source: "spellfix",
    system: CHECK,
    prompt: checkPrompt(text, flagged),
    model: MODEL,
    maxTokens: replyBudget(distinct.size),
    timeoutMs: 20_000,
    signal,
  });
  if ("text" in reply) return parseReply(reply.text, text, distinct);
  // Closing the review aborts the call on purpose; a replaced session has no UI left.
  if (signal.aborted || gen !== sessionGen) return undefined;
  toast(ctx, `spellfix: ${MODEL} failed: ${reply.error}`, "warning");
  return undefined;
}

/** `findings` from hunspell's misses and the model's extras, at their first occurrence in the draft. */
function toFindings(
  misses: readonly Miss[],
  extras: readonly Extra[],
  verdicts: ReadonlyMap<string, Verdict>,
): Finding[] {
  const byWord = new Map<string, Miss[]>();
  for (const m of misses) {
    const seen = byWord.get(m.word);
    if (seen) seen.push(m);
    else byWord.set(m.word, [m]);
  }
  const findings: Finding[] = [];
  for (const [word, offsets] of byWord) {
    const verdict = verdicts.get(word);
    const fix = verdict?.kind === "fix" ? verdict.word : null;
    // A fix that only changes case reads as a casing slip, not a typo.
    const kind = fix && fix.toLowerCase() === word.toLowerCase() ? "casing" : "typo";
    findings.push({
      word,
      fix,
      kind: verdict?.kind === "unsure" ? "unsure" : kind,
      offsets,
      checked: true,
    });
  }
  for (const extra of extras) {
    findings.push({
      word: extra.word,
      fix: extra.fix,
      kind: "real word",
      offsets: [{ word: extra.word, start: extra.start, end: extra.end }],
      checked: true,
    });
  }
  return findings.sort((a, b) => a.offsets[0]!.start - b.offsets[0]!.start);
}

function setUnderlined(misses: readonly (Miss | Extra)[]) {
  const words = new Set(misses.map((m) => m.word));
  if (words.size === 0 && underlined.size === 0) return;
  underlined = words;
  editor?.requestRender();
}

/** The cached batch's extras when it is for `text`, skipped words left out. */
function cachedExtras(text: string): Extra[] {
  return batch?.text === text ? batch.extras.filter((x) => !ignored.has(x.word)) : [];
}

/**
 * The draft as the editor holds it, a large paste still its `[paste #n]`
 * marker: the words in a paste are neither checked nor sent to the model.
 */
function draftText(ctx: ExtensionContext): string {
  return editor?.getText() ?? ctx.ui.getEditorText();
}

/** pi's own test for a draft it runs as a shell command (`!cmd`, `!!cmd`). */
function isShellDraft(text: string): boolean {
  return text.trimStart().startsWith("!");
}

/** The cursor as an offset into `getText`, for "nearest misspelling". */
function cursorOffset(draft: PromptDraft): number {
  const { line, col } = draft.getCursor();
  const lines = draft.getLines();
  let offset = 0;
  for (let i = 0; i < line && i < lines.length; i++) offset += lines[i]!.length + 1;
  return offset + col;
}

/** Puts back a draft read with `draftText`, keeping the pastes its markers name. */
function writeDraft(ui: ExtensionUIContext, text: string) {
  if (editor) editor.replaceText(text);
  else ui.setEditorText(text);
}

/** Hunspell's misses plus the cached model extras, in draft order. */
async function allMisses(
  gen: number,
  ctx: ExtensionContext,
  text: string,
): Promise<(Miss | Extra)[]> {
  return withExtras(await findMisses(gen, ctx, text), cachedExtras(text));
}

/* ------------------------------------------------------------------ editor */

function styleWords(
  line: string,
  words: ReadonlySet<string>,
  style: (word: string) => string,
): string {
  let out = "";
  let last = 0;
  for (const m of line.matchAll(ESCAPE)) {
    const index = m.index!;
    out += line
      .slice(last, index)
      .replace(WORD_IN_TEXT, (word) => (words.has(word) ? style(word) : word));
    out += m[0];
    last = index + m[0].length;
  }
  return (
    out + line.slice(last).replace(WORD_IN_TEXT, (word) => (words.has(word) ? style(word) : word))
  );
}

/** The prompt editor's line with the misspelled words underlined. */
function underline(line: string): string {
  if (underlined.size === 0 || !live) return line;
  const theme = live.ui.theme;
  return styleWords(line, underlined, (word) =>
    theme.style(word, { fg: "error", underline: true }),
  );
}

/** Tells spellfix the prompt editor's draft changed; it repaints the editor once a check lands. */
function onEdit(draft: PromptDraft) {
  editor = draft;
  const text = draft.getText();
  if (text === editedText) return;
  editedText = text;
  if (live) scheduleCheck(sessionGen, live);
}

/* ------------------------------------------------------------------ review */

/**
 * A rounded box whose every line is filled to `width`. Padding is what keeps
 * the editor underneath from showing through the overlay's short lines.
 */
function box(theme: Theme, width: number, title: string, body: string[]): string[] {
  const inner = Math.max(1, width - 2);
  const fill = (line: string) => truncateToWidth(line, inner, "…", true);
  const label = truncateToWidth(` ${title} `, inner);
  const rest = Math.max(0, inner - visibleWidth(label));
  const left = Math.floor(rest / 2);
  return [
    theme.fg("border", `╭${"─".repeat(left)}`) +
      theme.fg("accent", label) +
      theme.fg("border", `${"─".repeat(rest - left)}╮`),
    ...body.map((line) => theme.fg("border", "│") + fill(` ${line}`) + theme.fg("border", "│")),
    theme.fg("border", `╰${"─".repeat(inner)}╯`),
  ];
}

/** Splits `items` into rows joined by `sep` that fit `width` instead of truncating them. */
function rows(items: readonly string[], width: number, sep: string): string[] {
  const out: string[] = [];
  let row = "";
  for (const item of items) {
    const next = row ? `${row}${sep}${item}` : item;
    if (row && visibleWidth(next) > width) {
      out.push(row);
      row = item;
    } else {
      row = next;
    }
  }
  if (row) out.push(row);
  return out;
}

/**
 * How many findings fit the overlay: pi clips an overlay at the bottom, so the
 * frame and the hints are budgeted before the list and a long one scrolls.
 */
function windowSize(): number {
  const terminal = process.stdout.rows ?? 40;
  const room = Math.floor(terminal * 0.8) - CHROME_LINES - 1;
  return Math.max(3, Math.min(MAX_FINDINGS, Math.floor(room / FINDING_LINES)));
}

/**
 * The review overlay. It owns the draft text while open: every applied fix
 * writes the whole editor text, since pi exposes no range replace. The editor
 * is not focused meanwhile, so no edit can land between reads.
 */
class Review implements Component {
  private text: string;
  private findings: Finding[] = [];
  private index = 0;
  private top = 0;
  private checking = true;
  private closed = false;
  private pendingAll = false;
  private aiError: string | undefined;
  private added = new Set<string>();
  private flagged: Miss[] = [];
  private readonly abort = new AbortController();

  constructor(
    private readonly tui: TUI,
    private readonly gen: number,
    private readonly ctx: ExtensionContext,
    private readonly ui: ExtensionUIContext,
    text: string,
    private readonly cursor: number,
    private readonly done: () => void,
  ) {
    this.text = text;
  }

  /** The review outlives its ctx when the session is replaced under it. */
  private get live(): boolean {
    return this.gen === sessionGen && !this.closed;
  }

  async start() {
    this.flagged = await findMisses(this.gen, this.ctx, this.text);
    if (!this.live) return;
    this.findings = toFindings(this.flagged, [], new Map());
    this.focusNearest();
    this.tui.requestRender();
    if (batch?.text === this.text) this.restore(batch);
    else void this.runModel();
  }

  private focusNearest() {
    this.index = 0;
    for (let i = 0; i < this.findings.length; i++) {
      const item = this.findings[i]!;
      const at = item.offsets[0]!;
      const best = this.findings[this.index]!.offsets[0]!;
      const distance = (m: Miss) =>
        this.cursor < m.start ? m.start - this.cursor : Math.max(0, this.cursor - m.end);
      if (distance(at) < distance(best)) this.index = i;
    }
  }

  private close() {
    if (this.closed) return;
    this.closed = true;
    this.abort.abort();
    this.done();
  }

  private clampIndex() {
    this.index = Math.max(0, Math.min(this.index, this.findings.length - 1));
  }

  /** Replaces `before` with `text` in the batch cache, so a reopened review is current. */
  private keepBatch(before: string) {
    if (batch?.text !== before) return;
    batch.text = this.text;
  }

  private repaint() {
    this.tui.requestRender();
  }

  /** The model has answered or failed: a waiting "apply all" can run, and its adds are named. */
  private settle() {
    this.checking = false;
    if (this.added.size) lastAdded = [...new Set([...lastAdded, ...this.added])];
    this.repaint();
    if (this.pendingAll) {
      this.pendingAll = false;
      this.applyChecked();
    }
  }

  /** Acts on a fresh answer, which may add words to the personal dictionary. */
  private async applyFresh(verdicts: ReadonlyMap<string, Verdict>, extras: readonly Extra[]) {
    const correct = autoAdds(verdicts, (word) => ignored.has(word) || unadded.has(word));
    if (correct.length) await addWords(this.gen, this.ctx, correct);
    if (!this.live) return;
    for (const word of correct) this.added.add(word);
    this.fill(verdicts, extras);
    this.settle();
  }

  /** Rebuilds the findings from the current answer, keeping every row's toggle and focus. */
  private fill(verdicts: ReadonlyMap<string, Verdict>, extras: readonly Extra[]) {
    const checked = new Map(this.findings.map((f) => [f.word, f.checked]));
    const focus = this.findings[this.index]?.word;
    const findings = toFindings(this.flagged, extras, verdicts).filter((f) => {
      if (ignored.has(f.word)) return false;
      // A word the model calls correct is out of the review, unless `u` put it back.
      return !(verdicts.get(f.word)?.kind === "correct" && !unadded.has(f.word));
    });
    for (const finding of findings) {
      const was = checked.get(finding.word);
      if (was !== undefined) finding.checked = was;
    }
    this.findings = findings;
    this.index = Math.max(
      0,
      focus === undefined
        ? 0
        : Math.max(
            0,
            findings.findIndex((f) => f.word === focus),
          ),
    );
  }

  /** Applies a cached answer without adding anything to the personal dictionary again. */
  private restore(result: { verdicts: Map<string, Verdict> }) {
    this.fill(result.verdicts, cachedExtras(this.text));
    this.settle();
  }

  /** The model's batch for the draft at open; fixes found for words already gone are ignored. */
  private async runModel() {
    const sent = this.text;
    const answer = await askModel(this.gen, this.ctx, sent, this.flagged, this.abort.signal);
    if (!this.live) return;
    if (!answer) {
      this.aiError = "no answer";
      this.settle();
      return;
    }
    const { verdicts, found } = answer;
    const variants = [...verdicts].flatMap(([word, v]) =>
      v.kind === "correct" ? caseVariants(word) : [],
    );
    recase(verdicts, await knownWords(this.gen, this.ctx, variants));
    if (!this.live) return;
    const extras = placeExtras(sent, found, this.flagged);
    batch = { text: sent, verdicts, extras };
    await this.applyFresh(verdicts, extras);
  }

  /** `finding`'s replacement at each of its occurrences. */
  private splices(finding: Finding): Splice[] {
    if (finding.fix === null) return [];
    const fix = finding.fix;
    return finding.offsets.map((o) => ({ start: o.start, end: o.end, text: fix }));
  }

  /** Moves every other finding past an edit at `start`..`end` that changed by `delta`. */
  private shiftOthers(start: number, end: number, delta: number) {
    for (const finding of this.findings) {
      finding.offsets = finding.offsets.flatMap((o) => shift(o, start, end, delta) ?? []);
    }
    this.findings = this.findings.filter((f) => f.offsets.length > 0);
    // A rebuild from `flagged` (undo add) reads these, so they move with it.
    this.flagged = this.flagged.flatMap((m) => shift(m, start, end, delta) ?? []);
  }

  /** Writes one finding into the draft and takes it off the list. */
  private applyOne(finding: Finding) {
    const before = this.text;
    for (const s of this.splices(finding).sort((a, b) => b.start - a.start)) {
      this.text = `${this.text.slice(0, s.start)}${s.text}${this.text.slice(s.end)}`;
      this.shiftOthers(s.start, s.end, s.text.length - (s.end - s.start));
    }
    if (this.text === before) return;
    this.keepBatch(before);
    this.findings = this.findings.filter((f) => f !== finding);
    this.clampIndex();
    writeDraft(this.ui, this.text);
    this.repaint();
    if (this.findings.length === 0) this.close();
  }

  /** Writes every checked finding into the draft and closes. */
  private applyChecked() {
    if (this.checking && this.findings.every((f) => f.fix === null)) {
      // The overlay can wait for the answer, unlike the Claude Code mod's hook.
      this.pendingAll = true;
      this.repaint();
      return;
    }
    const edits = this.findings.filter((f) => f.checked).flatMap((f) => this.splices(f));
    if (edits.length === 0) {
      toast(this.ctx, "No fixes from the model", "info");
      return;
    }
    const before = this.text;
    this.text = applyEdits(before, edits);
    this.keepBatch(before);
    writeDraft(this.ui, this.text);
    this.close();
  }

  private toggle() {
    const finding = this.findings[this.index];
    if (!finding) return;
    finding.checked = !finding.checked;
    this.repaint();
  }

  /** Adds the focused word to the personal dictionary and takes its rows off the list. */
  private async keep() {
    const finding = this.findings[this.index];
    // Extras are typos the model found; none belongs in the dictionary.
    if (!finding || finding.kind === "real word") return;
    if (!PERSONAL) {
      toast(this.ctx, "spellfix: no personal dictionary configured", "warning");
      return;
    }
    await addWords(this.gen, this.ctx, [finding.word]);
    if (!this.live) return;
    this.findings = this.findings.filter((f) => f.word !== finding.word);
    this.clampIndex();
    this.repaint();
    if (this.findings.length === 0) this.close();
  }

  /** Takes this answer's auto-added words back out and puts their rows back. */
  private async undoAdd() {
    if (this.added.size === 0) return;
    const words = [...this.added];
    this.added.clear();
    lastAdded = lastAdded.filter((w) => !words.includes(w));
    await removeWords(this.gen, this.ctx, words);
    if (!this.live) return;
    this.flagged = await findMisses(this.gen, this.ctx, this.text);
    if (!this.live) return;
    this.fill(batch?.verdicts ?? new Map(), cachedExtras(this.text));
    this.repaint();
  }

  private move(by: number) {
    if (this.findings.length === 0) return;
    this.index = (this.index + by + this.findings.length) % this.findings.length;
    this.repaint();
  }

  invalidate(): void {}

  handleInput(data: string): void {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
      this.close();
      return;
    }
    if (matchesKey(data, Key.up) || matchesKey(data, "k") || matchesKey(data, "p")) {
      this.move(-1);
      return;
    }
    if (matchesKey(data, Key.down) || matchesKey(data, "j") || matchesKey(data, "n")) {
      this.move(1);
      return;
    }
    if (matchesKey(data, "space")) {
      this.toggle();
      return;
    }
    if (matchesKey(data, Key.enter) || matchesKey(data, Key.return)) {
      const finding = this.findings[this.index];
      if (finding) this.applyOne(finding);
      return;
    }
    if (matchesKey(data, "a")) {
      this.applyChecked();
      return;
    }
    if (matchesKey(data, "d")) {
      void this.keep();
      return;
    }
    if (matchesKey(data, "u")) {
      void this.undoAdd();
      return;
    }
  }

  /** The focused finding's line of the draft, with `word` struck and its fix in green. */
  private diffLine(finding: Finding, width: number): string {
    const theme = this.ui.theme;
    const at = finding.offsets[0]!;
    const lead = this.text.slice(Math.max(0, at.start - CONTEXT), at.start).replace(/\s+/g, " ");
    const tail = this.text
      .slice(at.end, Math.min(this.text.length, at.end + CONTEXT))
      .replace(/\s+/g, " ");
    const diff =
      finding.fix === null
        ? theme.style(finding.word, { fg: "warning", underline: true })
        : wordDiff(finding.word, finding.fix)
            .map((run) =>
              run.kind === "removed"
                ? theme.style(run.text, { fg: "error", strikethrough: true })
                : run.kind === "added"
                  ? theme.style(run.text, { fg: "success" })
                  : run.text,
            )
            .join(" ");
    const line =
      theme.fg("dim", `${at.start > CONTEXT ? "…" : ""}${lead}`) +
      diff +
      theme.fg("dim", `${tail}${at.end + CONTEXT < this.text.length ? "…" : ""}`);
    return truncateToWidth(line, width - 4, "…");
  }

  render(width: number): string[] {
    const theme = this.ui.theme;
    const checked = this.findings.filter((f) => f.checked && f.fix !== null).length;
    const title = this.findings.length
      ? `spellfix · ${checked} to apply · ${this.findings.length} found`
      : "spellfix";
    const body: string[] = [""];

    if (this.findings.length === 0) {
      body.push(
        theme.fg("muted", this.checking ? "Checking for misspellings…" : "No misspellings left."),
      );
      body.push("");
      body.push(theme.fg("dim", "esc close"));
      return box(theme, width, title, body);
    }

    const window = windowSize();
    if (this.index - this.top >= window) this.top = this.index - window + 1;
    if (this.index < this.top) this.top = this.index;

    this.findings.slice(this.top, this.top + window).forEach((finding, offset) => {
      const focused = this.top + offset === this.index;
      const mark = focused ? theme.fg("accent", "❯") : " ";
      const check = finding.checked ? theme.fg("success", "☑") : theme.fg("dim", "☐");
      const count = finding.offsets.length > 1 ? ` ×${finding.offsets.length}` : "";
      body.push(`${mark} ${check} ${theme.fg("dim", `[${finding.kind}]`)}${count}`);
      const keeps = finding.fix === null ? theme.fg("dim", " · d keeps it") : "";
      body.push(`  ${this.diffLine(finding, width)}${keeps}`);
    });

    const below = this.findings.length - (this.top + window);
    if (below > 0) body.push(theme.fg("dim", `  ${below} more below`));
    body.push(theme.fg("dim", `${this.index + 1}/${this.findings.length}`));

    const hints: string[] = [];
    if (checked) hints.push("a apply all");
    hints.push("enter apply");
    hints.push("space toggle");
    if (this.findings[this.index]?.kind !== "real word") hints.push("d keep word");
    if (this.added.size) hints.push("u undo add");
    hints.push("esc close");
    const notes: string[] = [];
    if (this.checking) notes.push("asking the model…");
    if (this.pendingAll) notes.push("waiting for the model…");
    if (this.aiError) notes.push(`model: ${this.aiError}`);
    if (this.added.size) notes.push(`added: ${[...this.added].join(", ")}`);
    for (const row of rows([...notes, ...hints], width - 4, " · ")) body.push(theme.fg("dim", row));

    return box(theme, width, title, body);
  }
}

/* ------------------------------------------------------------------- wiring */

function scheduleCheck(gen: number, ctx: ExtensionContext) {
  if (suspended || gen !== sessionGen) return;
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = undefined;
    void refreshUnderlines(gen, ctx);
  }, CHECK_DELAY_MS);
}

/** Underlines the draft's misspellings. */
async function refreshUnderlines(gen: number, ctx: ExtensionContext) {
  if (gen !== sessionGen) return;
  const id = ++checkId;
  const text = draftText(ctx);
  if (!text.trim() || isShellDraft(text)) {
    setUnderlined([]);
    return;
  }
  const misses = await allMisses(gen, ctx, text);
  if (id !== checkId || gen !== sessionGen) return;
  setUnderlined(misses);
}

async function openReview(ctx: ExtensionContext) {
  if (ctx.mode !== "tui") {
    toast(ctx, "spellfix: the review needs the interactive UI", "warning");
    return;
  }
  const text = draftText(ctx);
  if (!text.trim()) {
    toast(ctx, "No misspellings", "info");
    return;
  }
  if (isShellDraft(text)) {
    toast(ctx, "spellfix: shell commands aren't spellchecked", "info");
    return;
  }
  const gen = sessionGen;
  const cursor = editor ? cursorOffset(editor) : text.length;
  suspended = true;
  if (timer) clearTimeout(timer);
  try {
    await ctx.ui.custom<void>(
      (tui, _theme, _kb, done) => {
        const review = new Review(tui, gen, ctx, ctx.ui, text, cursor, done);
        void review.start();
        return review;
      },
      {
        overlay: true,
        overlayOptions: { anchor: "bottom-center", width: "85%", maxHeight: "80%", margin: 1 },
      },
    );
  } finally {
    suspended = false;
    if (gen === sessionGen) scheduleCheck(gen, ctx);
  }
}

/** `/spellfix undo`: takes the last answer's auto-added words back out of the dictionary. */
async function undoLastAdded(ctx: ExtensionContext) {
  const words = lastAdded;
  if (words.length === 0) {
    toast(ctx, "spellfix: nothing to undo", "info");
    return;
  }
  lastAdded = [];
  await removeWords(sessionGen, ctx, words);
  toast(ctx, `spellfix: removed ${words.join(", ")} from the dictionary`, "info");
}

export default function (pi: ExtensionAPI, { editorHooks }: Services) {
  api = pi;
  editorHooks.add({ decorateLine: underline, onEdit });
  pi.registerShortcut("ctrl+q", {
    description: "Review spelling in the prompt draft",
    handler: (ctx) => openReview(ctx),
  });

  pi.registerCommand("spellfix", {
    description: "Review the draft's spelling, or `undo` the last words it learned",
    handler: async (args, ctx) => {
      if (args.trim() === "undo") return undoLastAdded(ctx);
      return openReview(ctx);
    },
  });

  pi.registerCommand("spellcheck", {
    description: "Review spelling in the prompt draft",
    handler: async (_args, ctx) => openReview(ctx),
  });

  pi.on("session_start", (_event, ctx) => {
    sessionGen++;
    const gen = sessionGen;
    ignored.clear();
    unadded.clear();
    lastAdded = [];
    batch = undefined;
    warnedHunspell = false;
    suspended = false;
    if (ctx.mode !== "tui") return;
    live = ctx;
    // hunspell neither creates a missing personal dictionary nor saves into one.
    void ensurePersonal();
    scheduleCheck(gen, ctx);
  });

  pi.on("session_shutdown", () => {
    sessionGen++;
    if (timer) clearTimeout(timer);
    timer = undefined;
    checkId++;
    suspended = false;
    live = undefined;
    editor = undefined;
    editedText = undefined;
    underlined = new Set();
    batch = undefined;
  });

  // A submitted or cleared draft starts with a clean ignore list, as in the Claude Code mod.
  pi.on("input", () => {
    ignored.clear();
    unadded.clear();
    lastAdded = [];
  });
}
