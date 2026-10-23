/**
 * Spelling fixes for the prompt draft, on the Claude Code spellfix mod's
 * core (modules/programs/claude-code/mods/spellfix). hunspell flags the words;
 * one model call answers every flagged word at once and finds real-word typos
 * hunspell cannot see (`form` for `from`).
 *
 * - Misspelled words are underlined in the editor, which pi's replaceable
 *   editor allows and the Claude Code composer does not.
 * - ctrl+q (or /spellcheck) opens a picker over the draft: numbers pick a fix,
 *   `s` skips, `d` adds to the personal dictionary, `a` applies every fix,
 *   `u` takes back words the model called correct, esc closes.
 * - Picks teach a fix log, so the fix picked most for a word leads its list.
 *
 * Shares the personal dictionary and fix log with the Claude Code mod, so a
 * word learned in one is known to the other; the core keeps their rules and
 * file formats the same.
 */
import { spawn } from "node:child_process";
import { mkdir, open, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import type { Model, UserMessage } from "@earendil-works/pi-ai";
import { CustomEditor, type Theme } from "@earendil-works/pi-coding-agent";
import type {
  ExtensionAPI,
  ExtensionContext,
  ExtensionUIContext,
  KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import { Key, matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { Component, EditorTheme, KeyId, TUI } from "@earendil-works/pi-tui";

import {
  addInput,
  autoAdds,
  candidates,
  caseVariants,
  CHECK,
  checkPrompt,
  countPicks,
  formatLog,
  hunspellArgs,
  isExtra,
  nearest,
  parseReply,
  parseSuggestions,
  placeExtras,
  recase,
  replyBudget,
  shift,
  suggestInput,
  topFix,
  withExtras,
  withoutWords,
} from "./lib/spellfix/hooks/core.ts";
import type { Found, LogPick, Verdict } from "./lib/spellfix/hooks/core.ts";
import type { Extra, FixLog, FixSource, Miss } from "./lib/spellfix/types/index.d.ts";
import { recordSideCall } from "./lib/usage-ledger.ts";
import { providePromptEditor } from "./lib/prompt-editor.ts";

type Suggestion = { word: string; source: FixSource };

const HUNSPELL = process.env.PI_SPELLFIX_HUNSPELL || "hunspell";
const DICTIONARIES = process.env.PI_SPELLFIX_DICTS || "en_US";
const PERSONAL = process.env.PI_SPELLFIX_PERSONAL || "";
const FIX_LOG = process.env.PI_SPELLFIX_LOG || "";
const MODEL = process.env.PI_SPELLFIX_MODEL || "";

const CHECK_DELAY_MS = 300;
const SUGGESTIONS = 5;
// "haiku" is the Claude Code mod's log key; keeping it shares the learned fixes.
const AI_SOURCE: FixSource = "haiku";

const WORD_IN_TEXT = /[\p{L}]+(?:['’][\p{L}]+)*/gu;
// SGR and APC, the only escapes the editor draws with. Text between them is
// safe to style without corrupting a sequence.
const ESCAPE = /\x1b\[[0-9;:?]*[ -/]*[@-~]|\x1b_[^\x07]*\x07/g;

/** Set at load; the batch call's spend is recorded through it. */
let api: ExtensionAPI | undefined;
/** Words skipped in the picker, forgotten once the draft is submitted or cleared. */
const ignored = new Set<string>();
// Auto-added words taken back with `u`; the model's "correct" leaves them flagged for this draft.
const unadded = new Set<string>();

let editor: SpellEditor | undefined;
let unsubscribeInput: (() => void) | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
let checkId = 0;
/** Bumped on session start and shutdown: a ctx captured before the bump is unusable. */
let sessionGen = 0;
let suspended = false;
let warnedHunspell = false;
let warnedModel = false;
let logging = Promise.resolve();

/**
 * The last model answer, kept for reopening the picker on the same draft
 * without paying for it again; `text` and the extras follow the picker's fixes.
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
    warnHunspell(ctx, error);
    return undefined;
  }
}

/** The candidates hunspell rejects, skipped words excluded; none when hunspell fails. */
async function findMisses(ctx: ExtensionContext, text: string): Promise<Miss[]> {
  const words = candidates(text).filter((w) => !ignored.has(w.word));
  if (words.length === 0) return [];
  const stdout = await runHunspell(
    ctx,
    "-l",
    `${[...new Set(words.map((w) => w.word))].join("\n")}\n`,
  );
  if (stdout === undefined) return [];
  const bad = new Set(stdout.split("\n").filter(Boolean));
  return words.filter((w) => bad.has(w.word));
}

/** The words of `words` hunspell accepts; none when it fails. */
async function knownWords(ctx: ExtensionContext, words: readonly string[]): Promise<Set<string>> {
  if (words.length === 0) return new Set();
  const stdout = await runHunspell(ctx, "-l", `${words.join("\n")}\n`);
  if (stdout === undefined) return new Set();
  const bad = new Set(stdout.split("\n"));
  return new Set(words.filter((w) => !bad.has(w)));
}

async function suggest(ctx: ExtensionContext, word: string): Promise<string[]> {
  const stdout = await runHunspell(ctx, "-a", suggestInput(word));
  return stdout === undefined ? [] : parseSuggestions(stdout, SUGGESTIONS);
}

/** Replaces `path` with `text` by renaming a temporary file over it, so no reader sees it half-written. */
async function writeAtomic(path: string, text: string) {
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, text);
  await rename(tmp, path);
}

async function addWords(ctx: ExtensionContext, words: readonly string[]) {
  for (const word of words) ignored.add(word);
  if (!PERSONAL || words.length === 0) return;
  await ensurePersonal();
  await runHunspell(ctx, "-a", addInput(words));
}

/** Takes auto-added words back out of the personal dictionary; hunspell itself cannot remove one. */
async function removeWords(ctx: ExtensionContext, words: readonly string[]) {
  for (const word of words) {
    ignored.delete(word);
    unadded.add(word);
  }
  if (!PERSONAL) return;
  try {
    await writeAtomic(PERSONAL, withoutWords(await readFile(PERSONAL, "utf8"), words));
  } catch (error) {
    toast(ctx, `spellfix: couldn't edit ${PERSONAL}: ${String(error)}`, "error");
  }
}

async function loadLog(): Promise<FixLog | undefined> {
  if (!FIX_LOG) return undefined;
  try {
    return JSON.parse(await readFile(FIX_LOG, "utf8")) as FixLog;
  } catch {
    // Missing starts a new log; one that won't parse is left alone rather than overwritten.
    try {
      await readFile(FIX_LOG);
      return undefined;
    } catch {
      return {};
    }
  }
}

/** Counts picks in the fix log, one write at a time so quick picks don't drop each other. */
function record(picks: readonly LogPick[]) {
  if (!FIX_LOG || picks.length === 0) return;
  logging = logging
    .then(async () => {
      const log = await loadLog();
      if (!log) return;
      const last = new Date().toISOString().slice(0, 10);
      await mkdir(dirname(FIX_LOG), { recursive: true });
      await writeAtomic(FIX_LOG, formatLog(countPicks(log, picks, last)));
    })
    .catch(() => undefined);
}

function pickModel(ctx: ExtensionContext): Model<string> | undefined {
  if (MODEL) {
    const slash = MODEL.indexOf("/");
    const found =
      slash > 0 ? ctx.modelRegistry.find(MODEL.slice(0, slash), MODEL.slice(slash + 1)) : undefined;
    if (found) return found;
    if (!warnedModel) {
      warnedModel = true;
      toast(ctx, `spellfix: PI_SPELLFIX_MODEL=${MODEL} is not a known model`, "warning");
    }
  }
  return ctx.model;
}

type Answer = { verdicts: Map<string, Verdict>; found: Found[] };

async function askModel(
  ctx: ExtensionContext,
  text: string,
  flagged: readonly Miss[],
  signal: AbortSignal,
): Promise<Answer | undefined> {
  const model = pickModel(ctx);
  if (!model) {
    toast(ctx, "spellfix: no model selected", "warning");
    return undefined;
  }
  const distinct = new Set(flagged.map((m) => m.word));
  const message: UserMessage = {
    role: "user",
    content: [{ type: "text", text: checkPrompt(text, flagged) }],
    timestamp: Date.now(),
  };
  try {
    const response = await ctx.modelRegistry
      .streamSimple(
        model,
        { systemPrompt: CHECK, messages: [message] },
        {
          maxTokens: replyBudget(distinct.size),
          temperature: 0,
          timeoutMs: 20_000,
          signal,
        },
      )
      .result();
    if (api) recordSideCall(api, "spellfix", response);
    if (response.stopReason === "error" || response.stopReason === "aborted") {
      throw new Error(response.errorMessage ?? response.stopReason);
    }
    const reply = response.content.flatMap((c) => (c.type === "text" ? [c.text] : [])).join("\n");
    return parseReply(reply, text, distinct);
  } catch (error) {
    toast(
      ctx,
      `spellfix: ${model.provider}/${model.id} failed: ${
        error instanceof Error ? error.message : String(error)
      }`,
      "warning",
    );
    return undefined;
  }
}

/**
 * Adds `text`'s misses and extras to `words`, which the editor underlines.
 * `words` is keyed by word, not offset: every occurrence of a flagged word is
 * marked, matching the underline the Claude Code mod draws.
 */
function underlinedWords(misses: readonly (Miss | Extra)[]): Set<string> {
  return new Set(misses.map((m) => m.word));
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

/** Puts back a draft read with `draftText`. */
function writeDraft(ui: ExtensionUIContext, text: string) {
  if (editor) editor.replaceDraft(text);
  else ui.setEditorText(text);
}

/** Hunspell's misses plus the cached model extras, in draft order. */
async function allMisses(ctx: ExtensionContext, text: string): Promise<(Miss | Extra)[]> {
  return withExtras(await findMisses(ctx, text), cachedExtras(text));
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

/**
 * The default editor with misspelled words underlined and a cursor offset the
 * picker can start from. `CustomEditor` keeps pi's shortcuts, history and
 * autocomplete; only `render` and the change signal are added.
 */
class SpellEditor extends CustomEditor {
  private words: ReadonlySet<string> = new Set();

  constructor(
    tui: TUI,
    editorTheme: EditorTheme,
    keybindings: KeybindingsManager,
    private readonly appTheme: () => Theme,
    private readonly onEdit: () => void,
  ) {
    // pi's own editor embeds the working status in its top border; a bare
    // CustomEditor would move it to the separate loader row.
    super(tui, editorTheme, keybindings, { embedWorkingStatus: true });
  }

  setUnderlined(words: ReadonlySet<string>) {
    this.words = words;
  }

  /** The cursor as an offset into `getText`, for "nearest misspelling". */
  cursorOffset(): number {
    const { line, col } = this.getCursor();
    const lines = this.getLines();
    let offset = 0;
    for (let i = 0; i < line && i < lines.length; i++) offset += lines[i]!.length + 1;
    return offset + col;
  }

  override handleInput(data: string): void {
    super.handleInput(data);
    this.onEdit();
  }

  override setText(text: string): void {
    super.setText(text);
    this.onEdit();
  }

  /** `setText` for a draft from `getText`, keeping the pastes its markers name. */
  replaceDraft(text: string): void {
    // pi-tui's paste map and counter are private, and setText clears them.
    const self = this as unknown as { pastes: Map<number, string>; pasteCounter: number };
    const pastes = new Map(self.pastes);
    const counter = self.pasteCounter;
    this.setText(text);
    for (const [id, paste] of pastes) self.pastes.set(id, paste);
    self.pasteCounter = counter;
  }

  override render(width: number): string[] {
    const lines = super.render(width);
    if (this.words.size === 0) return lines;
    const theme = this.appTheme();
    return lines.map((line) =>
      styleWords(line, this.words, (word) => theme.style(word, { fg: "error", underline: true })),
    );
  }
}

/* ------------------------------------------------------------------ picker */

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

type PickerResult = { changed: boolean };

/**
 * The overlay picker. It owns the draft text while open: every fix writes the
 * whole editor text, since pi exposes no range replace. The editor is not
 * focused meanwhile, so no edit can land between reads.
 */
class SpellPicker implements Component {
  private text: string;
  private items: (Miss | Extra)[] = [];
  private index = 0;
  private ai = new Map<string, string>();
  private aiDone = false;
  private aiError: string | undefined;
  private suggestions = new Map<string, Suggestion[]>();
  private added = new Set<string>();
  private closed = false;
  private pendingAll = false;
  private flagged: Miss[] = [];
  // Fixes made while the model call is out, replayed on its extras when it lands.
  private edits: { start: number; end: number; delta: number }[] = [];
  private readonly abort = new AbortController();

  constructor(
    private readonly tui: TUI,
    private readonly gen: number,
    private readonly ctx: ExtensionContext,
    private readonly ui: ExtensionUIContext,
    text: string,
    private readonly cursor: number,
    private readonly done: (result: PickerResult) => void,
  ) {
    this.text = text;
  }

  /** The picker outlives its ctx when the session is replaced under it. */
  private get live(): boolean {
    return this.gen === sessionGen && !this.closed;
  }

  async start() {
    this.flagged = await findMisses(this.ctx, this.text);
    if (!this.live) return;
    this.items = withExtras(this.flagged, cachedExtras(this.text));
    const near = nearest(this.items, this.cursor);
    this.index = near ? Math.max(0, this.items.indexOf(near)) : 0;
    this.prefetch();
    this.tui.requestRender();
    if (batch?.text === this.text) this.restore(batch);
    else void this.runModel();
  }

  private get item(): Miss | Extra | undefined {
    return this.items[this.index];
  }

  private close(result: PickerResult = { changed: false }) {
    if (this.closed) return;
    this.closed = true;
    this.abort.abort();
    this.done(result);
  }

  /** Replaces start..end of the picker's text with `fix`, keeping the batch's extras in place. */
  private splice(start: number, end: number, fix: string) {
    const before = this.text;
    const delta = fix.length - (end - start);
    this.text = `${before.slice(0, start)}${fix}${before.slice(end)}`;
    if (batch?.text === before) {
      batch.text = this.text;
      batch.extras = batch.extras.flatMap((x) => shift(x, start, end, delta) ?? []);
    }
    if (!this.aiDone) this.edits.push({ start, end, delta });
  }

  private changed() {
    writeDraft(this.ui, this.text);
    this.prefetch();
    this.tui.requestRender();
  }

  private async prefetch() {
    const item = this.item;
    if (!item || isExtra(item) || this.suggestions.has(item.word)) return;
    const log = await loadLog();
    if (!this.live) return;
    const guess = topFix(log, item.word);
    const hunspell = await suggest(this.ctx, item.word);
    if (!this.live) return;
    const list: Suggestion[] = [];
    if (guess) list.push({ word: guess, source: "history" });
    for (const word of hunspell) {
      if (!list.some((s) => s.word === word)) list.push({ word, source: "hunspell" });
    }
    this.suggestions.set(item.word, list.slice(0, SUGGESTIONS));
    this.tui.requestRender();
  }

  /** The model's batch for the draft at open; fixes found for words already gone are ignored. */
  private async runModel() {
    const sent = this.text;
    const answer = await askModel(this.ctx, sent, this.flagged, this.abort.signal);
    if (!this.live) return;
    if (!answer) {
      this.aiError = "no answer";
      this.aiDone = true;
      this.tui.requestRender();
      return;
    }
    const { verdicts, found } = answer;
    const variants = [...verdicts].flatMap(([word, v]) =>
      v.kind === "correct" ? caseVariants(word) : [],
    );
    recase(verdicts, await knownWords(this.ctx, variants));
    if (!this.live) return;
    let extras = placeExtras(sent, found, this.flagged);
    for (const e of this.edits)
      extras = extras.flatMap((x) => shift(x, e.start, e.end, e.delta) ?? []);
    batch = { text: this.text, verdicts, extras };
    await this.applyFresh(verdicts);
  }

  /** Acts on a fresh answer, which may add words to the personal dictionary. */
  private async applyFresh(verdicts: ReadonlyMap<string, Verdict>) {
    for (const [word, verdict] of verdicts) {
      if (verdict.kind === "fix") this.ai.set(word, verdict.word);
    }
    const correct = autoAdds(verdicts, (word) => ignored.has(word) || unadded.has(word));
    if (correct.length) {
      await addWords(this.ctx, correct);
      if (!this.live) return;
      for (const word of correct) this.added.add(word);
      this.items = this.items.filter((item) => !correct.includes(item.word));
    }
    this.items = withExtras(this.items, cachedExtras(this.text));
    this.index = Math.max(0, Math.min(this.index, this.items.length - 1));
    this.aiDone = true;
    this.prefetch();
    await this.refreshUnderline();
    if (this.pendingAll) {
      this.pendingAll = false;
      void this.fixAll();
    }
  }

  /** Applies a cached answer without adding anything to the personal dictionary again. */
  private restore(result: { verdicts: Map<string, Verdict> }) {
    for (const [word, verdict] of result.verdicts) {
      if (verdict.kind === "fix") this.ai.set(word, verdict.word);
    }
    this.items = this.items.filter(
      (item) => !(result.verdicts.get(item.word)?.kind === "correct" && !unadded.has(item.word)),
    );
    this.index = Math.max(0, Math.min(this.index, this.items.length - 1));
    this.aiDone = true;
    this.prefetch();
    this.tui.requestRender();
  }

  /** Rebuilds the editor's underlines from the current answers, once they land. */
  private async refreshUnderline() {
    if (editor) editor.setUnderlined(underlinedWords(this.items));
    this.tui.requestRender();
  }

  private aiFix(item: Miss | Extra): string | null {
    return this.ai.get(item.word) ?? (isExtra(item) ? item.fix : null);
  }

  private pick(fix: string, source: FixSource) {
    const item = this.item;
    if (!item) return;
    const ai = this.aiFix(item);
    if (ai && ai !== fix) record([{ from: item.word, to: ai, as: "rejected" }]);
    record([{ from: item.word, to: fix, as: source }]);

    const delta = fix.length - (item.end - item.start);
    this.splice(item.start, item.end, fix);
    this.items = this.items
      .filter((m) => m !== item)
      .flatMap((m) => shift(m, item.start, item.end, delta) ?? []);
    this.index = Math.min(this.index, Math.max(0, this.items.length - 1));
    this.changed();
    if (this.items.length === 0) this.close({ changed: true });
  }

  private skip() {
    const item = this.item;
    if (!item) return;
    const ai = this.aiFix(item);
    if (ai) record([{ from: item.word, to: ai, as: "rejected" }]);
    ignored.add(item.word);
    this.items = this.items.filter((m) => m !== item);
    this.index = Math.min(this.index, Math.max(0, this.items.length - 1));
    this.tui.requestRender();
    if (this.items.length === 0) this.close();
  }

  private async add() {
    const item = this.item;
    // Extras are typos the model found; none belongs in the dictionary.
    if (!item || isExtra(item)) return;
    if (!PERSONAL) {
      toast(this.ctx, "spellfix: no personal dictionary configured", "warning");
      return;
    }
    await addWords(this.ctx, [item.word]);
    if (!this.live) return;
    this.items = this.items.filter((m) => m !== item);
    this.index = Math.min(this.index, Math.max(0, this.items.length - 1));
    this.tui.requestRender();
    if (this.items.length === 0) this.close();
  }

  private async undoAdd() {
    const words = [...this.added];
    if (words.length === 0) return;
    this.added.clear();
    await removeWords(this.ctx, words);
    if (!this.live) return;
    this.items = await allMisses(this.ctx, this.text);
    if (!this.live) return;
    this.index = Math.max(0, Math.min(this.index, this.items.length - 1));
    this.prefetch();
    this.tui.requestRender();
  }

  private async fixAll() {
    if (!this.aiDone) {
      // The overlay can wait for the answer, unlike the Claude Code mod's hook.
      this.pendingAll = true;
      this.tui.requestRender();
      return;
    }
    const fixes = this.items.flatMap((item) => {
      const fix = this.aiFix(item);
      return fix ? [{ item, fix }] : [];
    });
    if (fixes.length === 0) {
      toast(this.ctx, "No fixes from the model", "info");
      return;
    }
    for (const { item, fix } of [...fixes].sort((a, b) => b.item.start - a.item.start)) {
      this.splice(item.start, item.end, fix);
    }
    record(fixes.map(({ item, fix }) => ({ from: item.word, to: fix, as: AI_SOURCE })));
    this.items = [];
    writeDraft(this.ui, this.text);
    this.close({ changed: true });
  }

  private move(by: number) {
    if (this.items.length === 0) return;
    this.index = (this.index + by + this.items.length) % this.items.length;
    this.prefetch();
    this.tui.requestRender();
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
    if (matchesKey(data, Key.enter) || matchesKey(data, Key.return)) {
      const item = this.item;
      if (!item) return;
      const fix = this.aiFix(item);
      if (fix) this.pick(fix, AI_SOURCE);
      else {
        const first = this.suggestions.get(item.word)?.[0];
        if (first) this.pick(first.word, first.source);
      }
      return;
    }
    if (matchesKey(data, "s")) {
      this.skip();
      return;
    }
    if (matchesKey(data, "d")) {
      void this.add();
      return;
    }
    if (matchesKey(data, "a")) {
      void this.fixAll();
      return;
    }
    if (matchesKey(data, "u")) {
      void this.undoAdd();
      return;
    }
    for (let n = 1; n <= 9; n++) {
      if (!matchesKey(data, String(n) as KeyId)) continue;
      const item = this.item;
      if (!item) return;
      if (n === 1) {
        const fix = this.aiFix(item);
        if (fix) this.pick(fix, AI_SOURCE);
        return;
      }
      const suggestion = this.suggestions.get(item.word)?.[n - 2];
      if (suggestion) this.pick(suggestion.word, suggestion.source);
      return;
    }
  }

  render(width: number): string[] {
    const theme = this.ui.theme;
    const item = this.item;
    const count = this.items.length;
    const title = item ? `spellfix · "${item.word}" · ${this.index + 1}/${count}` : "spellfix";
    const body: string[] = [""];

    if (!item) {
      body.push(
        theme.fg("muted", this.aiDone ? "No misspellings left." : "Checking for misspellings…"),
      );
      body.push("");
      body.push(theme.fg("dim", "esc close"));
      return box(theme, width, title, body);
    }

    const from = Math.max(0, item.start - 30);
    const to = Math.min(this.text.length, item.end + 30);
    const before = this.text.slice(from, item.start).replace(/\s+/g, " ");
    const after = this.text.slice(item.end, to).replace(/\s+/g, " ");
    body.push(
      theme.fg("dim", `${from > 0 ? "…" : ""}${before}`) +
        theme.style(item.word, {
          fg: isExtra(item) ? "warning" : "error",
          bold: true,
          underline: true,
        }) +
        theme.fg("dim", `${after}${to < this.text.length ? "…" : ""}`),
    );
    body.push("");

    const ai = this.aiFix(item);
    const actions: string[] = [];
    if (ai) {
      actions.push(
        `${theme.fg("accent", "1")} ${theme.style(ai, { bold: true })} ${theme.fg("dim", "(model)")}`,
      );
    } else if (!this.aiDone) {
      actions.push(theme.fg("dim", "1 …"));
    }
    const suggestions = this.suggestions.get(item.word) ?? [];
    suggestions.forEach((suggestion, i) => {
      actions.push(
        theme.fg("accent", String(i + 2)) +
          " " +
          suggestion.word +
          (suggestion.source === "history" ? theme.fg("dim", " (history)") : ""),
      );
    });
    if (!this.suggestions.has(item.word) && !isExtra(item)) actions.push(theme.fg("dim", "…"));
    for (const row of rows(actions, width - 4, "  ")) body.push(row);
    body.push("");

    const hints: string[] = [];
    if (ai || suggestions.length) hints.push("enter fix");
    hints.push("s skip");
    if (PERSONAL && !isExtra(item)) hints.push("d add");
    hints.push("a fix all");
    if (this.added.size) hints.push("u undo add");
    hints.push("↑/↓ next", "esc close");
    for (const row of rows(hints, width - 4, " · ")) body.push(theme.fg("dim", row));

    const notes: string[] = [];
    if (this.pendingAll) notes.push("waiting for the model…");
    if (this.added.size) notes.push(`added: ${[...this.added].join(", ")}`);
    if (this.aiError) notes.push(`model: ${this.aiError}`);
    if (notes.length) {
      body.push("");
      body.push(theme.fg("dim", notes.join(" · ")));
    }

    return box(theme, width, title, body);
  }
}

/* ------------------------------------------------------------------- wiring */

function scheduleCheck(gen: number, ctx: ExtensionContext) {
  if (suspended || gen !== sessionGen) return;
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = undefined;
    void refreshCount(gen, ctx);
  }, CHECK_DELAY_MS);
}

/** Updates the underline and the "N misspelled" widget from the draft. */
async function refreshCount(gen: number, ctx: ExtensionContext) {
  if (gen !== sessionGen) return;
  const id = ++checkId;
  const text = draftText(ctx);
  if (!text.trim()) {
    editor?.setUnderlined(new Set());
    ctx.ui.setWidget("spellfix", undefined);
    return;
  }
  const misses = await allMisses(ctx, text);
  if (id !== checkId || gen !== sessionGen) return;
  editor?.setUnderlined(underlinedWords(misses));
  if (suspended) return;
  // The word still being typed waits until the cursor moves past it, as the underline does.
  const cursor = editor?.cursorOffset() ?? Number.POSITIVE_INFINITY;
  const count = misses.filter((m) => m.end !== cursor).length;
  const theme = ctx.ui.theme;
  ctx.ui.setWidget(
    "spellfix",
    count > 0
      ? [theme.fg("error", `${count} misspelled`) + theme.fg("dim", " · ctrl+q")]
      : undefined,
  );
}

async function openPicker(ctx: ExtensionContext) {
  if (ctx.mode !== "tui") {
    toast(ctx, "spellfix: the picker needs the interactive UI", "warning");
    return;
  }
  const text = draftText(ctx);
  if (!text.trim()) {
    toast(ctx, "No misspellings", "info");
    return;
  }
  const gen = sessionGen;
  const cursor = editor?.cursorOffset() ?? text.length;
  suspended = true;
  if (timer) clearTimeout(timer);
  ctx.ui.setWidget("spellfix", undefined);
  try {
    await ctx.ui.custom<PickerResult>(
      (tui, _theme, _kb, done) => {
        const picker = new SpellPicker(tui, gen, ctx, ctx.ui, text, cursor, done);
        void picker.start();
        return picker;
      },
      {
        overlay: true,
        overlayOptions: { anchor: "bottom-center", width: "80%", maxHeight: 14, margin: 1 },
      },
    );
  } finally {
    suspended = false;
    if (gen === sessionGen) scheduleCheck(gen, ctx);
  }
}

export default function (pi: ExtensionAPI) {
  api = pi;
  pi.registerShortcut("ctrl+q", {
    description: "Fix spelling in the prompt draft",
    handler: (ctx) => openPicker(ctx),
  });

  pi.registerCommand("spellcheck", {
    description: "Fix spelling in the prompt draft",
    handler: async (_args, ctx) => openPicker(ctx),
  });

  pi.on("session_start", (_event, ctx) => {
    sessionGen++;
    const gen = sessionGen;
    ignored.clear();
    unadded.clear();
    batch = undefined;
    warnedHunspell = false;
    warnedModel = false;
    suspended = false;
    if (ctx.mode !== "tui") return;
    // hunspell neither creates a missing personal dictionary nor saves into one.
    void ensurePersonal();
    unsubscribeInput?.();
    editor = undefined;
    providePromptEditor(ctx, (tui, editorTheme, keybindings) => {
      editor = new SpellEditor(
        tui,
        editorTheme,
        keybindings,
        () => ctx.ui.theme,
        () => scheduleCheck(gen, ctx),
      );
      return editor;
    });
    // Also catches edits made without the custom editor, e.g. after another
    // extension replaces it: the picker then starts from the end of the draft.
    unsubscribeInput = ctx.ui.onTerminalInput(() => {
      scheduleCheck(gen, ctx);
      return undefined;
    });
    scheduleCheck(gen, ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    sessionGen++;
    if (timer) clearTimeout(timer);
    timer = undefined;
    checkId++;
    suspended = false;
    unsubscribeInput?.();
    unsubscribeInput = undefined;
    editor = undefined;
    batch = undefined;
    if (ctx.mode === "tui") ctx.ui.setWidget("spellfix", undefined);
  });

  // A submitted or cleared draft starts with a clean ignore list, as in the Claude Code mod.
  pi.on("input", () => {
    ignored.clear();
    unadded.clear();
  });
}
