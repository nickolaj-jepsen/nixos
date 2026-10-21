import { atom, read, update } from "claude-code";
import type { EngineInterface, PluginOptions, PromptBox, Register, Timer } from "claude-code";

import type { Miss, Picker, Report } from "../types";

// Borrowed: mods can't define keybinding actions, and nothing handles this one
// while the built-in cc-plugin-diff mod is enabled. A key bound to it in
// keybindings.json presses the band's button from the prompt.
const ACTION = "app:toggleDiffNoiseFilter";
const PLUGIN = "spellfix";
const SUGGESTIONS = 5;
const CHECK_DELAY_MS = 300;

const count = atom({ plugin: "spellfix", key: "count" } as const, 0);
const picker = atom({ plugin: "spellfix", key: "picker" } as const, null);
const report = atom({ plugin: "spellfix", key: "report" } as const, null);
const isBusy = atom({ plugin: "spellfix", key: "isBusy" } as const, false);

type Config = { hunspell: string; dictionaries: string; personal: string };

let config: Config = { hunspell: "hunspell", dictionaries: "en_US", personal: "" };
// Words skipped in the picker, forgotten once the draft is submitted or cleared.
const ignored = new Set<string>();
let timer: Timer | undefined;
let checkId = 0;
let hasWarned = false;

const FIX_ALL = `You correct spelling mistakes and obvious typos in a draft message a developer is about to send to a coding assistant.

Rules:
- Fix only misspelled words, typos, doubled or missing letters, and wrong capitalisation of "I".
- Keep the wording, word order, grammar, tone, punctuation and line breaks exactly as written.
- The draft may be in English or Danish, or mix both; never translate.
- Never touch code, file paths, URLs, identifiers, command names, flags, @mentions, /slash-commands, or anything inside backticks.
- If nothing needs fixing, return the draft unchanged.

Reply with the corrected draft inside <fixed></fixed> tags and nothing else.`;

const FIX_WORD = `A developer's draft message (English, Danish, or both) has one word marked with ⟦ ⟧ that a spell checker flagged. Reply with the word they most likely meant, in the same language and casing, inside <word></word> tags and nothing else. If the marked word is already correct, reply with it unchanged.`;

function readConfig(options: PluginOptions): Config {
  const text = (key: string, fallback: string) => {
    const value = options[key];
    return typeof value === "string" && value !== "" ? value : fallback;
  };
  return {
    hunspell: text("hunspell", "hunspell"),
    dictionaries: text("dictionaries", "en_US"),
    personal: text("personalDictionary", ""),
  };
}

function hunspellArgv(mode: "-l" | "-a"): string[] {
  const personal = config.personal ? ["-p", config.personal] : [];
  return [config.hunspell, mode, "-d", config.dictionaries, ...personal];
}

const SKIPPED_SCRIPTS =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]/u;

/** The words to check, by the built-in spellcheck's documented rules: code-like text is left out. */
function candidates(text: string): Miss[] {
  const masked = text.replace(/```[\s\S]*?(?:```|$)|`[^`\n]*`?/g, (m) => " ".repeat(m.length));
  const out: Miss[] = [];
  for (const tok of masked.matchAll(/\S+/g)) {
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

async function runHunspell(
  $: EngineInterface,
  mode: "-l" | "-a",
  stdin: string,
): Promise<string | undefined> {
  try {
    const r = await $.process.run(hunspellArgv(mode), { stdin, timeoutMs: 5000 });
    if (r.exitCode === 0) return r.stdout;
    throw new Error(r.stderr.trim() || `exit ${r.exitCode}`);
  } catch (error) {
    if (!hasWarned) {
      hasWarned = true;
      $.ui.toast(
        `spellfix: hunspell failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    return undefined;
  }
}

/** The candidates hunspell rejects, skipped words excluded; none when hunspell fails. */
async function findMisses($: EngineInterface, text: string): Promise<Miss[]> {
  const words = candidates(text).filter((w) => !ignored.has(w.word));
  if (words.length === 0) return [];
  const stdout = await runHunspell(
    $,
    "-l",
    `${[...new Set(words.map((w) => w.word))].join("\n")}\n`,
  );
  if (stdout === undefined) return [];
  const bad = new Set(stdout.split("\n").filter(Boolean));
  return words.filter((w) => bad.has(w.word));
}

async function suggest($: EngineInterface, word: string): Promise<string[]> {
  // `^` keeps hunspell's pipe mode from reading the word as a command.
  const stdout = await runHunspell($, "-a", `^${word}\n`);
  const line = stdout?.split("\n").find((l) => l.startsWith("& "));
  return line?.split(": ")[1]?.split(", ").filter(Boolean).slice(0, SUGGESTIONS) ?? [];
}

async function addWord($: EngineInterface, word: string) {
  ignored.add(word);
  // `*` adds to the personal dictionary and `#` saves it.
  if (config.personal) await runHunspell($, "-a", `*${word}\n#\n`);
}

function scheduleCheck($: EngineInterface, box: PromptBox) {
  timer?.cancel();
  timer = $.clock.after(CHECK_DELAY_MS, () => void refreshCount($, box));
}

async function refreshCount($: EngineInterface, box: PromptBox) {
  const id = ++checkId;
  // The word still being typed waits until the cursor moves past it, as the underline does.
  const n = (await findMisses($, box.text)).filter((m) => m.end !== box.cursor).length;
  if (id === checkId && (await read($, count)) !== n) await update($, count, () => n);
}

function nearest(found: readonly Miss[], cursor: number): Miss | undefined {
  const distance = (m: Miss) => (cursor < m.start ? m.start - cursor : Math.max(0, cursor - m.end));
  return found.reduce<Miss | undefined>(
    (best, m) => (!best || distance(m) < distance(best) ? m : best),
    undefined,
  );
}

/** Opens the picker on the misspelled word at or nearest the cursor; closes it when open. */
async function togglePicker($: EngineInterface) {
  if (await read($, picker)) {
    await closePicker($);
    return;
  }
  const { text, cursor } = await $.prompt.read();
  const target = nearest(await findMisses($, text), cursor);
  if (target) await show($, text, target);
  else $.ui.toast("No misspellings");
}

async function show($: EngineInterface, text: string, miss: Miss) {
  const suggestions = await suggest($, miss.word);
  const before = text.slice(Math.max(0, miss.start - 30), miss.start).replace(/\s+/g, " ");
  const after = text.slice(miss.end, miss.end + 30).replace(/\s+/g, " ");
  const shown: Picker = {
    ...miss,
    before,
    after,
    suggestions,
    ai: null,
    isAiDone: false,
    wantsAi: false,
  };
  await update($, picker, () => shown);
  void askHaiku($, text, miss);
}

async function askHaiku($: EngineInterface, text: string, miss: Miss) {
  const marked = `${text.slice(Math.max(0, miss.start - 500), miss.start)}⟦${miss.word}⟧${text.slice(miss.end, miss.end + 500)}`;
  const r = await $.model.complete({
    model: "haiku",
    system: FIX_WORD,
    prompt: marked,
    effort: "low",
    maxTokens: 64,
    timeoutMs: 10000,
  });
  const ai = r.isAnswered ? (/<word>\s*(.+?)\s*<\/word>/.exec(r.text)?.[1] ?? null) : null;
  const p = await read($, picker);
  if (!p || p.start !== miss.start || p.word !== miss.word) return;
  const answered: Picker = { ...p, ai, isAiDone: true, wantsAi: false };
  await update($, picker, () => answered);
  const choice = aiChoice(answered);
  if (p.wantsAi && choice) await applyLate($, answered, choice);
}

/** Applies a pick made before its answer arrived; outside an edit, so the cursor ends up at the end. */
async function applyLate($: EngineInterface, p: Picker, choice: string) {
  const box = await $.prompt.read();
  if (box.text.slice(p.start, p.end) !== p.word) return;
  const fixed = splice(box, p, choice);
  await $.prompt.fill({ text: fixed.text, mode: "replace" });
  await advance($, fixed.text, p.start + choice.length);
}

async function closePicker($: EngineInterface) {
  if (await read($, picker)) await update($, picker, () => null);
}

/** Moves the picker to the next misspelled word at or after `from`, wrapping; closes it when none are left. */
async function advance($: EngineInterface, text: string, from: number) {
  const found = await findMisses($, text);
  const next = found.find((m) => m.start >= from) ?? found[0];
  if (next) {
    await show($, text, next);
    return;
  }
  await closePicker($);
  $.ui.toast("No misspellings left");
}

/** `p` replaced by `replacement` in `box`, the cursor kept on the same text. */
function splice(box: PromptBox, p: Miss, replacement: string): PromptBox {
  const delta = replacement.length - (p.end - p.start);
  const cursor =
    box.cursor >= p.end ? box.cursor + delta : Math.min(box.cursor, p.start + replacement.length);
  return { text: `${box.text.slice(0, p.start)}${replacement}${box.text.slice(p.end)}`, cursor };
}

/** What Haiku's slot holds: its word, or null while it thinks, has none, or calls the word correct. */
function aiChoice(p: Picker): string | null {
  return p.ai && p.ai.toLowerCase() !== p.word.toLowerCase() ? p.ai : null;
}

/**
 * Answers one picker key against the draft in `box`: the box afterwards, or
 * undefined when `key` is not a picker key (the caller closes the picker).
 */
async function pick(
  $: EngineInterface,
  key: string,
  box: PromptBox,
): Promise<PromptBox | undefined> {
  const p = await read($, picker);
  if (!p || box.text.slice(p.start, p.end) !== p.word) return undefined;

  if (key === "s" || key === "d") {
    if (key === "d") await addWord($, p.word);
    else ignored.add(p.word);
    await advance($, box.text, p.end);
    return box;
  }
  if (key === "a") {
    void fixAll($);
    return box;
  }
  if (!/^[1-9]$/.test(key)) return undefined;

  // The edit hook can't wait out Haiku (its budget is milliseconds): the answer applies when it lands.
  if (key === "1" && !p.isAiDone) {
    const waiting: Picker = { ...p, wantsAi: true };
    await update($, picker, () => waiting);
    return box;
  }
  const choice = key === "1" ? aiChoice(p) : p.suggestions[Number(key) - 2];
  // A digit with nothing behind it is swallowed, never typed into the draft.
  if (!choice) return box;

  const fixed = splice(box, p, choice);
  await advance($, fixed.text, p.start + choice.length);
  return fixed;
}

/** A picker key pressed on the band itself (a click, or its hotkey while the band holds the keys). */
async function pickFromBand($: EngineInterface, key: string) {
  const box = await $.prompt.read();
  const fixed = await pick($, key, box);
  if (fixed && fixed.text !== box.text) await $.prompt.fill({ text: fixed.text, mode: "replace" });
}

/** The word-level changes from `a` to `b`, as `old→new`, `+added` and `−removed`. */
function diffWords(a: string, b: string): string[] {
  const x = a.split(/\s+/).filter(Boolean);
  const y = b.split(/\s+/).filter(Boolean);
  if (x.length * y.length > 4_000_000) return ["the draft"];
  const lcs = Array.from({ length: x.length + 1 }, () => new Array<number>(y.length + 1).fill(0));
  for (let i = x.length - 1; i >= 0; i--) {
    for (let j = y.length - 1; j >= 0; j--) {
      lcs[i]![j] =
        x[i] === y[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }
  const changes: string[] = [];
  let removed: string[] = [];
  let added: string[] = [];
  const flush = () => {
    if (removed.length && removed.length === added.length)
      changes.push(...removed.map((r, k) => `${r}→${added[k]}`));
    else if (removed.length && added.length)
      changes.push(`${removed.join(" ")}→${added.join(" ")}`);
    else if (removed.length) changes.push(`−${removed.join(" ")}`);
    else if (added.length) changes.push(`+${added.join(" ")}`);
    removed = [];
    added = [];
  };
  let i = 0;
  let j = 0;
  while (i < x.length || j < y.length) {
    if (i < x.length && j < y.length && x[i] === y[j]) {
      flush();
      i++;
      j++;
    } else if (j < y.length && (i === x.length || lcs[i]![j + 1]! >= lcs[i + 1]![j]!)) {
      added.push(y[j++]!);
    } else {
      removed.push(x[i++]!);
    }
  }
  flush();
  return changes;
}

async function fixAll($: EngineInterface) {
  await closePicker($);
  const { text } = await $.prompt.read();
  if (text.trim() === "" || (await read($, isBusy))) return;
  await update($, isBusy, () => true);
  try {
    const r = await $.model.complete({
      model: "haiku",
      system: FIX_ALL,
      prompt: `<draft>\n${text}\n</draft>`,
      effort: "low",
      maxTokens: Math.min(64000, Math.ceil(text.length / 2) + 256),
      timeoutMs: 20000,
    });
    const fixed = r.isAnswered ? /<fixed>\n?([\s\S]*?)\n?<\/fixed>/.exec(r.text)?.[1] : undefined;
    if (!fixed?.trim()) {
      $.ui.toast(`Spelling fix failed: ${r.isAnswered ? "unexpected reply" : r.reason}`);
      return;
    }
    if ((await $.prompt.read()).text !== text) {
      $.ui.toast("Draft changed while fixing; left it alone");
      return;
    }
    if (fixed === text) {
      $.ui.toast("No spelling mistakes found");
      return;
    }
    const done: Report = { original: text, fixed, changes: diffWords(text, fixed) };
    await update($, report, () => done);
    await $.prompt.fill({ text: fixed, mode: "replace" });
  } finally {
    await update($, isBusy, () => false);
  }
}

/** Takes back the last whole-draft fix while the draft is still exactly what it produced. */
async function undo($: EngineInterface, box: PromptBox): Promise<PromptBox | undefined> {
  const r = await read($, report);
  await update($, report, () => null);
  return r && box.text === r.fixed ? { text: r.original, cursor: r.original.length } : undefined;
}

async function undoFromBand($: EngineInterface) {
  const restored = await undo($, await $.prompt.read());
  if (restored) await $.prompt.fill({ text: restored.text, mode: "replace" });
}

export const register: Register = (on, options) => {
  config = readConfig(options);

  on("prompt.edit", async ($, e, next) => {
    const key = e.key && !e.key.ctrl && !e.key.meta ? e.key.key : undefined;
    const box = { text: e.text, cursor: e.cursor };

    if (key && (await read($, picker))) {
      const picked = await pick($, key, box);
      if (picked) {
        scheduleCheck($, picked);
        return picked;
      }
    }
    await closePicker($);

    if (await read($, report)) {
      const restored = key === "u" ? await undo($, box) : undefined;
      if (restored) {
        scheduleCheck($, restored);
        return restored;
      }
      await update($, report, () => null);
    }

    const edited = await next(e);
    scheduleCheck($, edited);
    return edited;
  });

  on("prompt.change", async ($, e, next) => {
    if (e.origin.kind === "clear") ignored.clear();
    // The picker's offsets and the report only hold for the draft they were made on.
    if (!(e.origin.kind === "plugin" && e.origin.name === PLUGIN)) {
      await closePicker($);
      if (await read($, report)) await update($, report, () => null);
    }
    scheduleCheck($, e);
    return next(e);
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e);
    const p = await read($, picker);
    const done = await read($, report);
    const busy = await read($, isBusy);
    const n = await read($, count);
    if (!p && !done && !busy && n === 0) return next(e);

    const { Box, Button, Text } = $.ui.resolve(e);
    // Kept mounted whenever the band shows: the key bound to ACTION reaches only a mounted Button.
    const toggle = (
      <Button key="spellfix" plain action={ACTION} onPress={() => togglePicker($)}>
        {p ? "close" : busy ? "Fixing spelling…" : `${n} misspelled`}
        <Text dimColor> ctrl+q</Text>
      </Button>
    );

    if (p) {
      const ai = aiChoice(p);
      return (
        <Box flexDirection="column">
          <Text wrap="truncate-end">
            <Text dimColor>…{p.before}</Text>
            <Text weight="bold" underline color="red">
              {p.word}
            </Text>
            <Text dimColor>{p.after}…</Text>
          </Text>
          <Box flexWrap="wrap" columnGap={2}>
            <Button key="ai" hotkey="1" plain onPress={() => pickFromBand($, "1")}>
              {!p.isAiDone
                ? p.wantsAi
                  ? "waiting…"
                  : "…"
                : (ai ?? (p.ai ? "looks correct" : "no idea"))}
              <Text dimColor> (Haiku)</Text>
            </Button>
            {p.suggestions.map((s, i) => (
              <Button
                key={`s${i}`}
                hotkey={String(i + 2)}
                plain
                onPress={() => pickFromBand($, String(i + 2))}
              >
                {s}
              </Button>
            ))}
            <Button key="skip" hotkey="s" plain label="skip" onPress={() => pickFromBand($, "s")} />
            {config.personal ? (
              <Button
                key="add"
                hotkey="d"
                plain
                label="add to dictionary"
                onPress={() => pickFromBand($, "d")}
              />
            ) : null}
            <Button
              key="all"
              hotkey="a"
              plain
              label="fix all"
              onPress={() => pickFromBand($, "a")}
            />
            {toggle}
          </Box>
        </Box>
      );
    }

    return (
      <Box columnGap={2}>
        {done && (
          <>
            <Text wrap="truncate-end">
              <Text dimColor>fixed: </Text>
              {done.changes.join(", ")}
            </Text>
            <Button key="undo" hotkey="u" plain label="undo" onPress={() => undoFromBand($)} />
          </>
        )}
        {(busy || n > 0) && toggle}
      </Box>
    );
  });
};
