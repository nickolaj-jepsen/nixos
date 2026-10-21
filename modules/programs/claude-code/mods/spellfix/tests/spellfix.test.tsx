import type { On, PromptBox, PromptEditInput, PromptEditResult } from "claude-code";
import { expect, mock, test } from "claude-code/testing";
import type { Engine, MockClock } from "claude-code/testing";

const BAND = {
  plugin: "spellfix",
  component: "AbovePrompt",
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const;

const OPTIONS = { options: { personalDictionary: "/personal.dic" } };

const usage = {
  input_tokens: 0,
  output_tokens: 0,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
};

type World = {
  clock: MockClock;
  box: PromptBox;
  personal: Set<string>;
};

// What the fake hunspell rejects, and what it suggests for each.
const DICT: Record<string, string[]> = {
  teh: ["the", "tech"],
  qiuck: ["quick", "quack"],
  recieve: ["receive"],
};

/** Stands in for the engine: the prompt box, hunspell (with its personal dictionary), Haiku and the band. */
function world(
  on: On,
  haiku: (prompt: string) => string | Promise<string> = () => "<word>the</word>",
): World {
  const w: World = { clock: mock.clock(on), box: { text: "", cursor: 0 }, personal: new Set() };
  const known = (word: string) => !(word in DICT) || w.personal.has(word);

  on("prompt.read", () => ({ value: w.box }));
  on("prompt.fill", (_, e) => {
    w.box = { text: e.text, cursor: e.text.length };
    return { isFilled: true };
  });
  on("prompt.edit", (_, e) => {
    const text = `${e.text.slice(0, e.start)}${e.inputText}${e.text.slice(e.end)}`;
    return { text, cursor: e.start + e.inputText.length };
  });
  on("prompt.change", (_, e) => ({ text: e.text }));
  on("process.run", (_, e) => {
    const lines = (e.init?.stdin ?? "").split("\n").filter(Boolean);
    let stdout = "";
    if (e.argv[1] === "-l") {
      stdout = lines.filter((word) => !known(word)).join("\n");
    } else {
      for (const line of lines) {
        if (line.startsWith("*")) w.personal.add(line.slice(1));
        if (line.startsWith("^") && !known(line.slice(1))) {
          stdout += `& ${line.slice(1)} 2 0: ${DICT[line.slice(1)]?.join(", ")}\n`;
        }
      }
    }
    return {
      value: {
        exitCode: 0,
        stdout,
        stderr: "",
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    };
  });
  on("model.complete", async (_, e) => ({
    value: { isAnswered: true, text: await haiku(e.prompt), usage },
  }));
  on("ui.toast", () => ({ value: undefined }));
  on("ui.render", ($, e) => {
    const { Text } = $.ui.resolve(e);
    return <Text>engine</Text>;
  });
  return w;
}

// The composer raises prompt.edit; the test engine runs it but doesn't type it.
function edit($: Engine, e: Omit<PromptEditInput, "origin">) {
  const prompt = $.prompt as unknown as { edit: (e: PromptEditInput) => Promise<PromptEditResult> };
  return prompt.edit({ origin: { kind: "composer" }, ...e });
}

/** Pastes `text` as the whole draft, the cursor left at `cursor` (its end by default). */
async function paste($: Engine, w: World, text: string, cursor = text.length) {
  await edit($, { text: "", cursor: 0, start: 0, end: 0, inputText: text });
  w.box = { text, cursor };
  await w.clock.advance(1000);
}

/** Types one key at the cursor, as the person does. */
async function key($: Engine, w: World, k: string) {
  const { text, cursor } = w.box;
  w.box = await edit($, {
    key: { key: k },
    text,
    cursor,
    start: cursor,
    end: cursor,
    inputText: k,
  });
  await w.clock.settle();
}

async function openPicker($: Engine, w: World) {
  const band = await $.ui.mount({ ...BAND, surface: "terminal" });
  await band.press({ key: "spellfix" });
  await w.clock.settle();
  return band;
}

for (const surface of ["terminal", "desktop"] as const) {
  test(`the band counts misspellings and hides without them (${surface})`, async ($, on) => {
    const w = world(on);

    await paste($, w, "the quick fox");
    const clean = await $.ui.mount({ ...BAND, surface });
    expect(await clean.find({ key: "spellfix" })).toBeUndefined();
    await clean.unmount();

    await paste($, w, "teh qiuck fox");
    const band = await $.ui.mount({ ...BAND, surface });
    expect((await band.find({ key: "spellfix" }))?.text).toContain("2 misspelled");
    await band.unmount();
  });
}

test("code, paths, flags and the word still being typed are not counted", async ($, on) => {
  const w = world(on);

  await paste($, w, "`teh` /teh --teh @teh teh_x teh.ts teh2 tehQ recieve");
  const band = await $.ui.mount({ ...BAND, surface: "terminal" });
  expect(await band.find({ key: "spellfix" })).toBeUndefined();

  await paste($, w, "recieve it");
  expect((await band.find({ key: "spellfix" }))?.text).toContain("1 misspelled");
  await band.unmount();
});

test("a picked suggestion replaces the word under the cursor and keeps the cursor in place", async ($, on) => {
  const w = world(on);

  await paste($, w, "the qiuck fox and teh dog", 6);
  const band = await openPicker($, w);
  expect(await band.find({ type: "Text", text: /qiuck/ })).toBeDefined();

  await key($, w, "2");
  expect(w.box).toEqual({ text: "the quick fox and teh dog", cursor: 6 });

  // The picker moved on to `teh`; Haiku's pick fixes it.
  await key($, w, "1");
  expect(w.box).toEqual({ text: "the quick fox and the dog", cursor: 6 });
  expect(await band.find({ key: "ai" })).toBeUndefined();
  await band.unmount();
});

test("pressing 1 before Haiku answers applies its word once it lands", async ($, on) => {
  let clock: MockClock | undefined;
  const w = world(on, async () => {
    await clock?.sleep(500);
    return "<word>quick</word>";
  });
  clock = w.clock;

  await paste($, w, "a qiuck fox");
  const band = await openPicker($, w);

  await key($, w, "1");
  expect(w.box.text).toBe("a qiuck fox");
  expect((await band.find({ key: "ai" }))?.text).toContain("waiting");

  await w.clock.advance(600);
  expect(w.box.text).toBe("a quick fox");
  await band.unmount();
});

test("skip moves to the next word and keeps skipped words out of the count", async ($, on) => {
  const w = world(on);

  await paste($, w, "teh qiuck fox");
  const band = await openPicker($, w);
  expect(await band.find({ type: "Text", text: /qiuck/ })).toBeDefined();

  await key($, w, "s");
  expect(await band.find({ type: "Text", text: /teh/ })).toBeDefined();
  await key($, w, "s");
  await w.clock.advance(1000);
  expect(w.box.text).toBe("teh qiuck fox");
  expect(await band.find({ key: "spellfix" })).toBeUndefined();
  await band.unmount();
});

test("any other key closes the picker and is typed", async ($, on) => {
  const w = world(on);

  await paste($, w, "a qiuck fox");
  const band = await openPicker($, w);

  await key($, w, "x");
  expect(w.box.text).toBe("a qiuck foxx");
  expect(await band.find({ key: "ai" })).toBeUndefined();
  await band.unmount();
});

test("add to dictionary keeps the word from being flagged again", OPTIONS, async ($, on) => {
  const w = world(on);

  await paste($, w, "a qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "d");
  expect(w.personal.has("qiuck")).toBe(true);
  expect(w.box.text).toBe("a qiuck fox");

  await paste($, w, "one more qiuck here");
  expect(await band.find({ key: "spellfix" })).toBeUndefined();
  await band.unmount();
});

test("fix all lists what changed and u undoes it", async ($, on) => {
  const w = world(on, (prompt) =>
    prompt.includes("<draft>") ? "<fixed>the quick fox</fixed>" : "<word>the</word>",
  );

  await paste($, w, "teh qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "a");
  expect(w.box.text).toBe("the quick fox");
  expect(await band.find({ type: "Text", text: /teh→the, qiuck→quick/ })).toBeDefined();

  await key($, w, "u");
  expect(w.box.text).toBe("teh qiuck fox");
  expect(await band.find({ key: "undo" })).toBeUndefined();
  await band.unmount();
});
