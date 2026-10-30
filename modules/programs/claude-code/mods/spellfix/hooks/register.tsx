import { atom, read, update } from "claude-code";
import type {
  EngineInterface,
  PluginOptions,
  PromptBox,
  Register,
  RenderElement,
  Timer,
} from "claude-code";

import type { Extra, Miss, Picker, Report } from "../types";
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
} from "./core";
import type { Verdict } from "./core";

// Borrowed: mods can't define keybinding actions, and nothing handles this one
// while the built-in cc-plugin-diff mod is enabled. A key bound to it in
// keybindings.json presses the band's button from the prompt.
const ACTION = "app:toggleDiffNoiseFilter";
const PLUGIN = "spellfix";
const SUGGESTIONS = 5;
const CHECK_DELAY_MS = 300;

const count = atom({ plugin: "spellfix", key: "count" } as const, 0);
const hasDraft = atom({ plugin: "spellfix", key: "hasDraft" } as const, false);
const picker = atom({ plugin: "spellfix", key: "picker" } as const, null);
const report = atom({ plugin: "spellfix", key: "report" } as const, null);
// Words the batch added to the personal dictionary on its own, until `8`, `9` or the next edit.
const added = atom({ plugin: "spellfix", key: "added" } as const, []);
// True while ctrl+q waits on the batch to find anything hunspell didn't.
const isBusy = atom({ plugin: "spellfix", key: "isBusy" } as const, false);

type Config = { hunspell: string; dictionaries: string; personal: string };

let config: Config = { hunspell: "hunspell", dictionaries: "en_US", personal: "" };
// Words skipped in the picker, forgotten once the draft is submitted or cleared.
const ignored = new Set<string>();
// Auto-added words taken back with `8`: the batch leaves them flagged for the rest of the draft.
const unadded = new Set<string>();
let timer: Timer | undefined;
let checkId = 0;
let hasWarned = false;

/** One Haiku call's answers for a draft; `text` follows the picker's own fixes. */
type Batch = {
  text: string;
  // The picker's fixes made while the call was out, replayed on the extras when it lands.
  edits: { start: number; end: number; delta: number }[];
  result?: { verdicts: Map<string, Verdict>; extras: Extra[] };
};

let batch: Batch | undefined;

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
  return [config.hunspell, ...hunspellArgs(mode, config.dictionaries, config.personal)];
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

/** The words of `words` hunspell accepts; none when it fails. */
async function knownWords($: EngineInterface, words: readonly string[]): Promise<Set<string>> {
  if (words.length === 0) return new Set();
  const stdout = await runHunspell($, "-l", `${words.join("\n")}\n`);
  if (stdout === undefined) return new Set();
  const bad = new Set(stdout.split("\n"));
  return new Set(words.filter((w) => !bad.has(w)));
}

/** hunspell's misses plus the batch's extras for `text`, in draft order. */
async function allMisses($: EngineInterface, text: string): Promise<(Miss | Extra)[]> {
  const extras = batch?.text === text ? (batch.result?.extras ?? []) : [];
  return withExtras(await findMisses($, text), extras);
}

/** Haiku's fix for `m` from the batch, if it has landed and has one. */
function fixFor(m: Miss | Extra): string | null {
  if (isExtra(m)) return m.fix;
  const v = batch?.result?.verdicts.get(m.word);
  return v?.kind === "fix" ? v.word : null;
}

function summarize(found: readonly (Miss | Extra)[]): string[] {
  return found.flatMap((m) => {
    const fix = fixFor(m);
    return fix ? [`${m.word}→${fix}${isExtra(m) ? "?" : ""}`] : [];
  });
}

async function suggest($: EngineInterface, word: string): Promise<string[]> {
  const stdout = await runHunspell($, "-a", suggestInput(word));
  return stdout === undefined ? [] : parseSuggestions(stdout, SUGGESTIONS);
}

async function addWords($: EngineInterface, words: readonly string[]) {
  for (const word of words) ignored.add(word);
  if (config.personal && words.length) await runHunspell($, "-a", addInput(words));
}

/** Takes auto-added words back out of the personal dictionary; hunspell itself can't remove one. */
async function removeWords($: EngineInterface, words: readonly string[]) {
  for (const word of words) {
    ignored.delete(word);
    unadded.add(word);
  }
  if (!config.personal) return;
  try {
    await $.fs.write(config.personal, withoutWords(await $.fs.read(config.personal), words));
  } catch (error) {
    $.ui.toast(`spellfix: couldn't edit ${config.personal}: ${String(error)}`);
  }
}

/** Keeps the batch on the draft through a fix the picker made to `text`. */
function noteSplice(text: string, m: Miss, replacement: string) {
  if (batch?.text !== text) return;
  const delta = replacement.length - (m.end - m.start);
  batch.text = `${text.slice(0, m.start)}${replacement}${text.slice(m.end)}`;
  if (!batch.result) batch.edits.push({ start: m.start, end: m.end, delta });
  else
    batch.result.extras = batch.result.extras.flatMap((x) => shift(x, m.start, m.end, delta) ?? []);
}

/** Starts the batch for `text` unless one for it is already out or in. */
function ensureBatch($: EngineInterface, text: string): Batch {
  if (batch?.text === text) return batch;
  const b: Batch = { text, edits: [] };
  batch = b;
  void runBatch($, b, text);
  return b;
}

async function runBatch($: EngineInterface, b: Batch, text: string) {
  const flagged = await findMisses($, text);
  const distinct = new Set(flagged.map((m) => m.word));
  const r = await $.model.complete({
    model: "haiku",
    system: CHECK,
    prompt: checkPrompt(text, flagged),
    effort: "low",
    maxTokens: replyBudget(distinct.size),
    timeoutMs: 20000,
  });
  if (!r.isAnswered) $.ui.toast(`spellfix: Haiku failed: ${r.reason}`);
  const { verdicts, found } = parseReply(r.isAnswered ? r.text : "", text, distinct);
  const variants = [...verdicts].flatMap(([word, v]) =>
    v.kind === "correct" ? caseVariants(word) : [],
  );
  recase(verdicts, await knownWords($, variants));
  let extras = placeExtras(text, found, flagged);
  for (const e of b.edits) extras = extras.flatMap((x) => shift(x, e.start, e.end, e.delta) ?? []);
  b.result = { verdicts, extras };
  if (batch === b) await landed($, b);
}

/** Acts on a batch's answers: adds the words it calls correct and brings the picker up to date. */
async function landed($: EngineInterface, b: Batch) {
  const correct = autoAdds(b.result!.verdicts, (word) => unadded.has(word) || ignored.has(word));
  await addWords($, correct);
  if (config.personal && correct.length) {
    await update($, added, (words) => [...new Set([...words, ...correct])]);
  }

  const { text, cursor } = await $.prompt.read();
  if (text !== b.text) {
    await update($, isBusy, () => false);
    return;
  }
  if (await read($, isBusy)) {
    await update($, isBusy, () => false);
    const found = await allMisses($, text);
    const target = nearest(found, cursor);
    if (target) await show($, text, target);
    else $.ui.toast(correct.length ? "No misspellings left" : "No misspellings");
    return;
  }

  const p = await read($, picker);
  if (!p) return;
  if (correct.includes(p.word) && !p.isExtra) {
    await advance($, text, p.start);
    return;
  }
  const found = await allMisses($, text);
  const answered: Picker = {
    ...p,
    ai: fixFor(found.find((m) => m.start === p.start) ?? p),
    isAiDone: true,
    wantsAi: false,
    wantsAll: false,
    summary: summarize(found),
  };
  await update($, picker, () => answered);
  if (p.wantsAll) await applyAllLate($);
  else if (p.wantsAi && answered.ai) await applyLate($, answered, answered.ai);
}

function scheduleCheck($: EngineInterface, box: PromptBox) {
  timer?.cancel();
  timer = $.clock.after(CHECK_DELAY_MS, () => void refreshCount($, box));
}

async function refreshCount($: EngineInterface, box: PromptBox) {
  const id = ++checkId;
  // The word still being typed waits until the cursor moves past it, as the underline does.
  const n = (await findMisses($, box.text)).filter((m) => m.end !== box.cursor).length;
  if (id !== checkId) return;
  if ((await read($, count)) !== n) await update($, count, () => n);
  const has = box.text.trim() !== "";
  if ((await read($, hasDraft)) !== has) await update($, hasDraft, () => has);
}

/**
 * Opens the picker on the misspelled word at or nearest the cursor, starting
 * the batch; with none flagged, opens once the batch finds one. Closes it when open.
 */
async function togglePicker($: EngineInterface) {
  if (await read($, picker)) {
    await closePicker($);
    return;
  }
  const { text, cursor } = await $.prompt.read();
  if (text.trim() === "") {
    $.ui.toast("No misspellings");
    return;
  }
  const b = ensureBatch($, text);
  const found = await allMisses($, text);
  const target = nearest(found, cursor);
  if (target) await show($, text, target);
  else if (!b.result) await update($, isBusy, () => true);
  else $.ui.toast("No misspellings");
}

async function show($: EngineInterface, text: string, miss: Miss | Extra) {
  const suggestions = isExtra(miss) ? [] : await suggest($, miss.word);
  const before = text.slice(Math.max(0, miss.start - 30), miss.start).replace(/\s+/g, " ");
  const after = text.slice(miss.end, miss.end + 30).replace(/\s+/g, " ");
  const isAiDone = batch?.text === text && batch.result !== undefined;
  const shown: Picker = {
    word: miss.word,
    start: miss.start,
    end: miss.end,
    before,
    after,
    suggestions,
    isExtra: isExtra(miss),
    ai: isAiDone ? fixFor(miss) : null,
    isAiDone,
    wantsAi: false,
    wantsAll: false,
    summary: isAiDone ? summarize(await allMisses($, text)) : [],
  };
  await update($, picker, () => shown);
}

/** Applies a pick made before its answer arrived; outside an edit, so the cursor ends up at the end. */
async function applyLate($: EngineInterface, p: Picker, choice: string) {
  const box = await $.prompt.read();
  if (box.text.slice(p.start, p.end) !== p.word) return;
  const fixed = splice(box, p, choice);
  noteSplice(box.text, p, choice);
  await $.prompt.fill({ text: fixed.text, mode: "replace" });
  await advance($, fixed.text, p.start + choice.length);
}

async function closePicker($: EngineInterface) {
  if (await read($, picker)) await update($, picker, () => null);
}

/** Moves the picker to the next misspelled word at or after `from`, wrapping; closes it when none are left. */
async function advance($: EngineInterface, text: string, from: number) {
  const found = await allMisses($, text);
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

/** Every fix the landed batch has, applied to `box` and reported for undo; undefined with none. */
async function applyAll($: EngineInterface, box: PromptBox): Promise<PromptBox | undefined> {
  const fixes = (await allMisses($, box.text)).flatMap((m) => {
    const fix = fixFor(m);
    return fix ? [{ ...m, fix }] : [];
  });
  await closePicker($);
  if (fixes.length === 0) {
    $.ui.toast("Nothing for Haiku to fix");
    return undefined;
  }
  let fixed = box;
  for (const f of [...fixes].reverse()) {
    noteSplice(fixed.text, f, f.fix);
    fixed = splice(fixed, f, f.fix);
  }
  const done: Report = {
    original: box,
    fixed: fixed.text,
    changes: fixes.map((f) => `${f.word}→${f.fix}`),
  };
  await update($, report, () => done);
  return fixed;
}

/** `a` pressed before the batch landed, applied now that it has. */
async function applyAllLate($: EngineInterface) {
  const box = await $.prompt.read();
  const fixed = await applyAll($, box);
  if (fixed) await $.prompt.fill({ text: fixed.text, mode: "replace" });
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
  if (key === "s" || (key === "d" && !p.isExtra && config.personal)) {
    if (key === "d") await addWords($, [p.word]);
    else if (p.isExtra && batch?.result) {
      batch.result.extras = batch.result.extras.filter((x) => x.start !== p.start);
    } else ignored.add(p.word);
    await advance($, box.text, p.end);
    return box;
  }
  if (key === "8") {
    const words = await read($, added);
    if (words.length === 0) return undefined;
    await update($, added, () => []);
    await removeWords($, words);
    await advance($, box.text, p.start);
    return box;
  }
  if (key === "a") {
    if (p.isAiDone) return (await applyAll($, box)) ?? box;
    const waiting: Picker = { ...p, wantsAll: true };
    await update($, picker, () => waiting);
    return box;
  }
  if (!/^[1-9]$/.test(key)) return undefined;

  // The edit hook can't wait out Haiku (its budget is milliseconds): the answer applies when it lands.
  if (key === "1" && !p.isAiDone) {
    const waiting: Picker = { ...p, wantsAi: true };
    await update($, picker, () => waiting);
    return box;
  }
  const choice = key === "1" ? p.ai : p.suggestions[Number(key) - 2];
  // A digit with nothing behind it is swallowed, never typed into the draft.
  if (!choice) return box;

  const fixed = splice(box, p, choice);
  noteSplice(box.text, p, choice);
  await advance($, fixed.text, p.start + choice.length);
  return fixed;
}

/** A picker key pressed on the band itself (a click, or its hotkey while the band holds the keys). */
async function pickFromBand($: EngineInterface, key: string) {
  const box = await $.prompt.read();
  const fixed = await pick($, key, box);
  if (fixed && fixed.text !== box.text) await $.prompt.fill({ text: fixed.text, mode: "replace" });
}

/**
 * Answers a key while the fix-all report or auto-added notice shows, like a picker key:
 * `8` takes back the fix-all (while the draft is still exactly what it produced) and the
 * auto-added words, `9` dismisses. The box afterwards, or undefined for any other key.
 */
async function answerReport(
  $: EngineInterface,
  key: string,
  box: PromptBox,
): Promise<PromptBox | undefined> {
  if (key !== "8" && key !== "9") return undefined;
  const r = await read($, report);
  const words = await read($, added);
  if (!r && words.length === 0) return undefined;
  await dismiss($);
  if (key === "9") return box;
  if (words.length) await removeWords($, words);
  return r && box.text === r.fixed ? r.original : box;
}

/** A report key pressed on the band itself. */
async function answerFromBand($: EngineInterface, key: string) {
  const box = await $.prompt.read();
  const answered = await answerReport($, key, box);
  if (answered && answered.text !== box.text) {
    await $.prompt.fill({ text: answered.text, mode: "replace" });
  }
}

/** Clears the fix-all report and the auto-added notice. */
async function dismiss($: EngineInterface) {
  if (await read($, report)) await update($, report, () => null);
  if ((await read($, added)).length) await update($, added, () => []);
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

    const answered = key ? await answerReport($, key, box) : undefined;
    if (answered) {
      scheduleCheck($, answered);
      return answered;
    }
    await dismiss($);

    const edited = await next(e);
    scheduleCheck($, edited);
    return edited;
  });

  on("prompt.change", async ($, e, next) => {
    if (e.origin.kind === "clear") {
      ignored.clear();
      unadded.clear();
    }
    // The picker's offsets and the report only hold for the draft they were made on.
    if (!(e.origin.kind === "plugin" && e.origin.name === PLUGIN)) {
      await closePicker($);
      await dismiss($);
    }
    scheduleCheck($, e);
    return next(e);
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e);
    // Another plugin's row (the answer mod's hint) stays drawn above this one.
    const below = await next(e);
    const p = await read($, picker);
    const done = await read($, report);
    const words = await read($, added);
    const busy = await read($, isBusy);
    const n = await read($, count);
    const draft = await read($, hasDraft);
    const isQuiet = !p && !done && !busy && n === 0 && words.length === 0;
    if (isQuiet && !draft) return below;

    const { Box, Button, Text } = $.ui.resolve(e);
    const stacked = (tree: RenderElement) => (
      <Box flexDirection="column">
        {below}
        {tree}
      </Box>
    );
    // Kept mounted whenever there's a draft: the key bound to ACTION reaches only a mounted Button.
    const toggle = (
      <Button key="spellfix" plain action={ACTION} onPress={() => togglePicker($)}>
        {p ? "close" : busy ? "Checking spelling…" : n ? `${n} misspelled` : "check spelling"}
        <Text dimColor> ctrl+q</Text>
      </Button>
    );
    // With nothing flagged it stays mounted for ctrl+q (Haiku may still find a typo), drawn in no cells.
    const hidden = (
      <Box key="hidden" width={0} height={0} overflow="hidden">
        {toggle}
      </Box>
    );
    if (isQuiet) return stacked(hidden);

    if (p) {
      const slot = p.isAiDone ? (p.ai ?? "no idea") : p.wantsAi ? "waiting…" : "…";
      // Ideally these would be marked inline in the prompt itself; mods can't decorate the
      // composer's text yet, so the band lists them instead.
      const summary = [...p.summary, ...(words.length ? [`added: ${words.join(", ")}`] : [])];
      return stacked(
        <Box flexDirection="column">
          <Text wrap="truncate-end">
            <Text dimColor>…{p.before}</Text>
            <Text weight="bold" underline color={p.isExtra ? "yellow" : "red"}>
              {p.word}
            </Text>
            <Text dimColor>{p.after}…</Text>
          </Text>
          <Box flexWrap="wrap" columnGap={2}>
            <Button key="ai" hotkey="1" plain onPress={() => pickFromBand($, "1")}>
              {slot}
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
            {config.personal && !p.isExtra ? (
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
              label={p.wantsAll ? "waiting…" : "fix all"}
              onPress={() => pickFromBand($, "a")}
            />
            {toggle}
          </Box>
          {summary.length > 0 && (
            <Box columnGap={2}>
              <Text wrap="truncate-end" dimColor>
                {summary.join(" · ")}
              </Text>
              {words.length > 0 && (
                <Button
                  key="undo"
                  hotkey="8"
                  plain
                  label="undo add"
                  onPress={() => pickFromBand($, "8")}
                />
              )}
            </Box>
          )}
        </Box>,
      );
    }

    const notes: [string, string][] = [
      ...(done ? [["fixed: ", done.changes.join(", ")] as [string, string]] : []),
      ...(words.length ? [["added: ", words.join(", ")] as [string, string]] : []),
    ];
    return stacked(
      <Box columnGap={2}>
        {notes.length > 0 && (
          <>
            <Text wrap="truncate-end">
              {notes.flatMap(([label, list], i) => [
                <Text key={`n${i}`} dimColor>
                  {i ? ` · ${label}` : label}
                </Text>,
                list,
              ])}
            </Text>
            <Button
              key="undo"
              hotkey="8"
              plain
              label="undo"
              onPress={() => answerFromBand($, "8")}
            />
            <Button
              key="dismiss"
              hotkey="9"
              plain
              label="dismiss"
              role="dismiss"
              onPress={() => answerFromBand($, "9")}
            />
          </>
        )}
        {busy || n > 0 ? toggle : hidden}
      </Box>,
    );
  });
};
