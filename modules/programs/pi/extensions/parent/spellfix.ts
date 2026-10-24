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
 *
 * Shares the personal dictionary with the Claude Code mod, so a word learned in
 * one is known to the other; the core keeps their rules and file format the same.
 */
import { spawn } from "node:child_process";
import { mkdir, open, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

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
  withExtras,
  withoutWords,
} from "./lib/spellfix/hooks/core.ts";
import type { Found, Verdict } from "./lib/spellfix/hooks/core.ts";
import type { Extra, Miss } from "./lib/spellfix/types/index.d.ts";
import { providePromptEditor, withdrawPromptEditor } from "./lib/prompt-editor.ts";
import { sideCall } from "../shared/side-call.ts";

const HUNSPELL = process.env.PI_SPELLFIX_HUNSPELL || "hunspell";
const DICTIONARIES = process.env.PI_SPELLFIX_DICTS || "en_US";
const PERSONAL = process.env.PI_SPELLFIX_PERSONAL || "";
// Not vm/flash: its reasoning DeepSeek would spend replyBudget thinking, and the
// picker waits on the call. Haiku keeps the one batch call cheap.
const MODEL = "anthropic/claude-haiku-5-5";

const CHECK_DELAY_MS = 300;
const SUGGESTIONS = 5;

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

async function suggest(gen: number, ctx: ExtensionContext, word: string): Promise<string[]> {
  const stdout = await runHunspell(gen, ctx, "-a", suggestInput(word));
  return stdout === undefined ? [] : parseSuggestions(stdout, SUGGESTIONS);
}

/** Replaces `path` with `text` by renaming a temporary file over it, so no reader sees it half-written. */
async function writeAtomic(path: string, text: string) {
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, text);
  await rename(tmp, path);
}

async function addWords(gen: number, ctx: ExtensionContext, words: readonly string[]) {
  for (const word of words) ignored.add(word);
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
  // Closing the picker aborts the call on purpose; a replaced session has no UI left.
  if (signal.aborted || gen !== sessionGen) return undefined;
  toast(ctx, `spellfix: ${MODEL} failed: ${reply.error}`, "warning");
  return undefined;
}

/** The words the editor underlines: by word, not offset, so every occurrence is marked. */
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

/** pi's own test for a draft it runs as a shell command (`!cmd`, `!!cmd`). */
function isShellDraft(text: string): boolean {
  return text.trimStart().startsWith("!");
}

/** Puts back a draft read with `draftText`. */
function writeDraft(ui: ExtensionUIContext, text: string) {
  if (editor) editor.replaceDraft(text);
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

  // pi's clipboard paste lands here once read, after its keystroke's check has run.
  override insertTextAtCursor(text: string): void {
    super.insertTextAtCursor(text);
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
  private suggestions = new Map<string, string[]>();
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
    this.flagged = await findMisses(this.gen, this.ctx, this.text);
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
    const hunspell = await suggest(this.gen, this.ctx, item.word);
    if (!this.live) return;
    this.suggestions.set(item.word, hunspell);
    this.tui.requestRender();
  }

  /** The model's batch for the draft at open; fixes found for words already gone are ignored. */
  private async runModel() {
    const sent = this.text;
    const answer = await askModel(this.gen, this.ctx, sent, this.flagged, this.abort.signal);
    if (!this.live) return;
    if (!answer) {
      this.aiError = "no answer";
      this.aiDone = true;
      this.tui.requestRender();
      if (this.pendingAll) {
        this.pendingAll = false;
        void this.fixAll();
      }
      return;
    }
    const { verdicts, found } = answer;
    const variants = [...verdicts].flatMap(([word, v]) =>
      v.kind === "correct" ? caseVariants(word) : [],
    );
    recase(verdicts, await knownWords(this.gen, this.ctx, variants));
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
      await addWords(this.gen, this.ctx, correct);
      if (!this.live) return;
      for (const word of correct) this.added.add(word);
      this.items = this.items.filter((item) => !correct.includes(item.word));
    }
    this.items = withExtras(this.items, cachedExtras(this.text));
    this.index = Math.max(0, Math.min(this.index, this.items.length - 1));
    this.aiDone = true;
    this.prefetch();
    this.refreshUnderline();
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
  private refreshUnderline() {
    if (editor) editor.setUnderlined(underlinedWords(this.items));
    this.tui.requestRender();
  }

  private aiFix(item: Miss | Extra): string | null {
    return this.ai.get(item.word) ?? (isExtra(item) ? item.fix : null);
  }

  private pick(fix: string) {
    const item = this.item;
    if (!item) return;
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
    await addWords(this.gen, this.ctx, [item.word]);
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
    await removeWords(this.gen, this.ctx, words);
    if (!this.live) return;
    this.items = await allMisses(this.gen, this.ctx, this.text);
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
      if (fix) this.pick(fix);
      else {
        const first = this.suggestions.get(item.word)?.[0];
        if (first) this.pick(first);
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
        if (fix) this.pick(fix);
        return;
      }
      const suggestion = this.suggestions.get(item.word)?.[n - 2];
      if (suggestion) this.pick(suggestion);
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
      actions.push(`${theme.fg("accent", String(i + 2))} ${suggestion}`);
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
    void refreshUnderlines(gen, ctx);
  }, CHECK_DELAY_MS);
}

/** Underlines the draft's misspellings. */
async function refreshUnderlines(gen: number, ctx: ExtensionContext) {
  if (gen !== sessionGen) return;
  const id = ++checkId;
  const text = draftText(ctx);
  if (!text.trim() || isShellDraft(text)) {
    editor?.setUnderlined(new Set());
    return;
  }
  const misses = await allMisses(gen, ctx, text);
  if (id !== checkId || gen !== sessionGen) return;
  editor?.setUnderlined(underlinedWords(misses));
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
  if (isShellDraft(text)) {
    toast(ctx, "spellfix: shell commands aren't spellchecked", "info");
    return;
  }
  const gen = sessionGen;
  const cursor = editor?.cursorOffset() ?? text.length;
  suspended = true;
  if (timer) clearTimeout(timer);
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

  // Closes over one session's ctx, so it is withdrawn when that session ends.
  let provided: Parameters<typeof providePromptEditor>[1] | undefined;

  pi.on("session_start", (_event, ctx) => {
    sessionGen++;
    const gen = sessionGen;
    ignored.clear();
    unadded.clear();
    batch = undefined;
    warnedHunspell = false;
    suspended = false;
    if (ctx.mode !== "tui") return;
    // hunspell neither creates a missing personal dictionary nor saves into one.
    void ensurePersonal();
    editor = undefined;
    provided = (tui, editorTheme, keybindings) => {
      editor = new SpellEditor(
        tui,
        editorTheme,
        keybindings,
        () => ctx.ui.theme,
        () => scheduleCheck(gen, ctx),
      );
      return editor;
    };
    providePromptEditor(ctx, provided);
    scheduleCheck(gen, ctx);
  });

  pi.on("session_shutdown", () => {
    sessionGen++;
    if (timer) clearTimeout(timer);
    timer = undefined;
    checkId++;
    suspended = false;
    editor = undefined;
    batch = undefined;
    if (provided) withdrawPromptEditor(provided);
    provided = undefined;
  });

  // A submitted or cleared draft starts with a clean ignore list, as in the Claude Code mod.
  pi.on("input", () => {
    ignored.clear();
    unadded.clear();
  });
}
