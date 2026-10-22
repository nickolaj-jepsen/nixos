import type { On, PromptBox, PromptEditInput, PromptEditResult } from "claude-code";
import { expect, mock, test } from "claude-code/testing";
import type { Engine, MockClock, Mounted } from "claude-code/testing";

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
const LOGGED = { options: { fixLog: "/fixes.json" } };

const usage = {
  input_tokens: 0,
  output_tokens: 0,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
};

type World = {
  clock: MockClock;
  box: PromptBox;
  files: Map<string, string>;
};

// What the fake hunspell rejects, and what it suggests for each.
const DICT: Record<string, string[]> = {
  teh: ["the", "tech"],
  qiuck: ["quick", "quack"],
  recieve: ["receive"],
  Jepsen: ["Jensen"],
};

/** Haiku's batch reply: each marked word fixed to hunspell's first suggestion, unless `say` has its own line. */
function haikuSays(say: Record<string, string> = {}, extras = "") {
  return (prompt: string) =>
    [...prompt.matchAll(/⟦(.+?)⟧/g)]
      .map(([, w = ""]) => say[w] ?? `<word text="${w}" verdict="fix">${DICT[w]?.[0]}</word>`)
      .join("\n") + extras;
}

const personal = (w: World) =>
  new Set((w.files.get("/personal.dic") ?? "").split("\n").filter(Boolean));

/** Stands in for the engine: the prompt box, files, hunspell (with its personal dictionary), Haiku and the band. */
function world(on: On, haiku: (prompt: string) => string | Promise<string> = haikuSays()): World {
  const w: World = { clock: mock.clock(on), box: { text: "", cursor: 0 }, files: new Map() };
  const known = (word: string) => !(word in DICT) || personal(w).has(word);

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
  on("fs.read", (_, e) => {
    const text = w.files.get(e.path);
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`);
    return { value: text };
  });
  on("fs.exists", (_, e) => ({ value: w.files.has(e.path) }));
  on("fs.write", (_, e) => {
    w.files.set(e.path, e.text);
    return { value: undefined };
  });
  on("process.run", (_, e) => {
    const lines = (e.init?.stdin ?? "").split("\n").filter(Boolean);
    let stdout = "";
    if (e.argv[1] === "-l") {
      stdout = lines.filter((word) => !known(word)).join("\n");
    } else {
      for (const line of lines) {
        if (line.startsWith("*")) {
          w.files.set("/personal.dic", `${w.files.get("/personal.dic") ?? ""}${line.slice(1)}\n`);
        }
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

/** The misspelling count the band shows, or "" while it shows none. */
async function shownCount(band: Pick<Mounted, "find">) {
  const text = (await band.find({ key: "spellfix" }))?.text ?? "";
  return /\d+ misspelled/.exec(text)?.[0] ?? "";
}

for (const surface of ["terminal", "desktop"] as const) {
  test(`the band counts misspellings and shows none without them (${surface})`, async ($, on) => {
    const w = world(on);

    await paste($, w, "the quick fox");
    const clean = await $.ui.mount({ ...BAND, surface });
    expect(await shownCount(clean)).toBe("");
    await clean.unmount();

    await paste($, w, "teh qiuck fox");
    const band = await $.ui.mount({ ...BAND, surface });
    expect(await shownCount(band)).toBe("2 misspelled");
    await band.unmount();
  });
}

test("code, paths, flags and the word still being typed are not counted", async ($, on) => {
  const w = world(on);

  await paste($, w, "`teh` /teh --teh @teh teh_x teh.ts teh2 tehQ recieve");
  const band = await $.ui.mount({ ...BAND, surface: "terminal" });
  expect(await shownCount(band)).toBe("");

  await paste($, w, "recieve it");
  expect(await shownCount(band)).toBe("1 misspelled");
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
  const w = world(on, async (prompt) => {
    await clock?.sleep(500);
    return haikuSays()(prompt);
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

test("one Haiku answer covers every word, so the next word's is there at once", async ($, on) => {
  let clock: MockClock | undefined;
  const w = world(on, async (prompt) => {
    await clock?.sleep(500);
    return haikuSays()(prompt);
  });
  clock = w.clock;

  await paste($, w, "teh qiuck fox", 0);
  const band = await openPicker($, w);
  await w.clock.advance(600);
  expect((await band.find({ key: "ai" }))?.text).toContain("the");

  await key($, w, "1");
  expect((await band.find({ key: "ai" }))?.text).toContain("quick");
  expect(await band.find({ type: "Text", text: /qiuck→quick/ })).toBeDefined();
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
  expect(await shownCount(band)).toBe("");
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
  const w = world(on, haikuSays({ qiuck: `<word text="qiuck" verdict="unsure"/>` }));

  await paste($, w, "a qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "d");
  expect(personal(w).has("qiuck")).toBe(true);
  expect(w.box.text).toBe("a qiuck fox");

  await paste($, w, "one more qiuck here");
  expect(await shownCount(band)).toBe("");
  await band.unmount();
});

test(
  "words Haiku calls correct are added to the dictionary and skipped, and 8 takes them back",
  OPTIONS,
  async ($, on) => {
    const w = world(on, haikuSays({ Jepsen: `<word text="Jepsen" verdict="correct"/>` }));

    await paste($, w, "ask Jepsen about teh fox", 0);
    const band = await openPicker($, w);
    expect(personal(w).has("Jepsen")).toBe(true);
    expect(await band.find({ type: "Text", text: /teh/ })).toBeDefined();
    expect(await band.find({ type: "Text", text: /added: Jepsen/ })).toBeDefined();

    await key($, w, "8");
    expect(personal(w).has("Jepsen")).toBe(false);
    expect(w.box.text).toBe("ask Jepsen about teh fox");
    // Taken back, it is flagged again and not re-added.
    expect(await band.find({ type: "Text", text: /Jepsen/ })).toBeDefined();
    await band.unmount();
  },
);

test("ctrl+q with nothing flagged offers the typos Haiku finds, and fix all applies them", async ($, on) => {
  const w = world(on, haikuSays({}, `<extra word="form" nth="2">from</extra>`));

  await paste($, w, "a form sent form home");
  const band = await openPicker($, w);
  expect(await band.find({ type: "Text", text: /^form$/ })).toBeDefined();
  expect((await band.find({ key: "ai" }))?.text).toContain("from");

  await key($, w, "a");
  expect(w.box.text).toBe("a form sent from home");
  expect(await band.find({ type: "Text", text: /form→from/ })).toBeDefined();

  await key($, w, "8");
  expect(w.box.text).toBe("a form sent form home");
  expect(await band.find({ key: "undo" })).toBeUndefined();
  await band.unmount();
});

test("typing after fix all just types, and drops the undo", async ($, on) => {
  const w = world(on);

  await paste($, w, "teh qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "a");
  await key($, w, "u");
  expect(w.box.text).toBe("the quick foxu");
  expect(await band.find({ key: "undo" })).toBeUndefined();
  await band.unmount();
});

test("the band's undo button takes back fix all", async ($, on) => {
  const w = world(on);

  await paste($, w, "teh qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "a");
  await band.press({ key: "undo" });
  await w.clock.settle();
  expect(w.box.text).toBe("teh qiuck fox");
  await band.unmount();
});

test("9 dismisses the fix-all report and keeps the fix", async ($, on) => {
  const w = world(on);

  await paste($, w, "teh qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "a");
  await key($, w, "9");
  expect(w.box.text).toBe("the quick fox");
  expect(await band.find({ key: "undo" })).toBeUndefined();
  await band.unmount();
});

test("an unmarked typo Haiku answers as a verdict is still offered", async ($, on) => {
  const w = world(on, () => `<word text="consice" verdict="fix">concise</word>`);

  await paste($, w, "dense/consice text");
  const band = await openPicker($, w);
  await key($, w, "a");
  expect(w.box.text).toBe("dense/concise text");
  await band.unmount();
});

test("fix all applies every word's answer at once", async ($, on) => {
  const w = world(on);

  await paste($, w, "teh qiuck fox");
  const band = await openPicker($, w);
  await key($, w, "a");
  expect(w.box.text).toBe("the quick fox");
  expect(await band.find({ type: "Text", text: /teh→the, qiuck→quick/ })).toBeDefined();
  await band.unmount();
});

test(
  "picks are counted in the fix log, and a fix picked before leads next time",
  LOGGED,
  async ($, on) => {
    let clock: MockClock | undefined;
    const w = world(on, async (prompt) => {
      await clock?.sleep(500);
      return haikuSays({ qiuck: `<word text="qiuck" verdict="fix">quack</word>` })(prompt);
    });
    clock = w.clock;

    await paste($, w, "a qiuck fox");
    let band = await openPicker($, w);
    await w.clock.advance(600);
    await key($, w, "2");
    await w.clock.settle();
    expect(JSON.parse(w.files.get("/fixes.json") ?? "{}")).toEqual({
      qiuck: {
        quick: expect.objectContaining({ hunspell: 1 }),
        quack: expect.objectContaining({ rejected: 1 }),
      },
    });
    await band.unmount();

    await paste($, w, "another qiuck");
    band = await openPicker($, w);
    expect((await band.find({ key: "ai" }))?.text).toContain("quick (history)");
    await key($, w, "1");
    expect(w.box.text).toBe("another quick");
    await band.unmount();
  },
);

test("Haiku's typos in words hunspell skips are offered, but never in code, URLs or commands", async ($, on) => {
  const w = world(
    on,
    haikuSays(
      {},
      [
        `<extra word="consice" nth="1">concise</extra>`,
        `<extra word="consice" nth="2">concise</extra>`,
        `<extra word="consice" nth="3">concise</extra>`,
        `<extra word="consice" nth="4">concise</extra>`,
      ].join("\n"),
    ),
  );

  await paste($, w, "dense/consice text, `consice` https://x.io/consice /consice");
  const band = await openPicker($, w);
  expect(await band.find({ type: "Text", text: /^consice$/ })).toBeDefined();

  await key($, w, "a");
  expect(w.box.text).toBe("dense/concise text, `consice` https://x.io/consice /consice");
  await band.unmount();
});
