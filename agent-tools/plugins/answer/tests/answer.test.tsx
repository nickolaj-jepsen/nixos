/**
 * The mod over the form's core, whose parser and steps have their own tests (`core/forms.spec.ts`).
 */
import type { On } from "claude-code";
import { expect, mock, test } from "claude-code/testing";
import type { Engine } from "claude-code/testing";

const GRILLING = `The bar and the funnel are independent, so this round asks both.

**Q1. Should every focus default to the same bar?**

- **A.** Yes, one default for every kind.
- **B.** Default by kind.
- **C.** Add the bar as a second pick.

> **Recommended:** A. A per-kind table is one more thing to keep in sync.

---

**Q2. Lower the per-generator target to 5–6?**

> **Recommended:** Yes. Four generators still give 20–24.

---

**Q3. What should happen to \`--quick\`?**

- **A.** Drop it.
- **B.** Keep it as an alias.
  Scripts may still call it.`;

const LONG = `**Q1. Keep the journal?**

${Array.from({ length: 12 }, (_, n) => `Line ${n + 1} of what it hangs on.`).join("\n")}

- **A.** Keep it.
- **B.** Drop it.`;

const MINE = `2 findings from 4 runs, saved to \`~/notes/FINDINGS.md\`

1. The default bar cuts the ideas you act on · 2/3 · S · build
2. The funnel is wide and slow for what survives · 3/3 · M · /grill-me

**Top pick: 1.** Make "worth doing" the default bar.`;

const PLAIN = `Done. What changed:

1. The parser takes \`Q\` labels and numbers.
2. The review screen fills the prompt.

Tests pass.`;

const BAND = {
  plugin: "answer",
  component: "AbovePrompt",
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 40,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const;

const RUN = {
  command: "answer",
  args: "",
  origin: { kind: "composer" },
  presentation: { isFullscreen: true, columns: 160 },
} as const;

type World = {
  box: string;
  submitted: string[];
  clock: ReturnType<typeof mock.clock>;
};

/** Stands in for the engine: the prompt box and the band beneath. */
function world(on: On, draft = ""): World {
  const w: World = { box: draft, submitted: [], clock: mock.clock(on) };
  on("prompt.read", () => ({ value: { text: w.box, cursor: w.box.length } }));
  on("prompt.fill", (_, e) => {
    w.box = e.text;
    return { isFilled: true };
  });
  on("prompt.submit", (_, e) => {
    w.submitted.push(e.text);
    return { text: e.text };
  });
  on("turn.complete", () => ({ text: "" }));
  on("command.register", () => ({ value: { command: "answer" } }));
  on("session.start", (_, e) => ({ cwd: e.cwd }));
  on("ui.focus", () => ({}));
  on("ui.toast", () => ({ value: undefined }));
  on("ui.log", () => ({ value: undefined }));
  on("ui.render", ($, e) => {
    const { Text } = $.ui.resolve(e);
    return <Text>engine</Text>;
  });
  return w;
}

const start = ($: Engine) =>
  $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });

const ends = ($: Engine, answer: string) =>
  $.turn.complete({ answer, reason: "answer", turnId: "t", durationMs: 1, isAborted: false });

const band = ($: Engine) => $.ui.mount({ ...BAND, surface: "terminal" });

/** The form's one row, while it is folded. */
const hint = async ($: Engine) => {
  const drawn = await band($);
  const found = await drawn.find({ key: "answer" });
  await drawn.unmount();
  return found?.text;
};

/** The band with the form open in it, as `/answer` opens it. */
const form = async ($: Engine) => {
  await $.command.run(RUN);
  return band($);
};

test("a turn that ends on questions offers the form; the person's next send drops it", async ($, on) => {
  world(on);
  await ends($, GRILLING);
  expect(await hint($)).toContain("Answer 3 questions");
  await $.prompt.submit({ text: "never mind", wait: false, origin: { kind: "composer" } });
  expect(await hint($)).toBeUndefined();
  await ends($, PLAIN);
  expect(await hint($)).toBeUndefined();
});

test("a background task's turn leaves the round and its answers alone", async ($, on) => {
  world(on);
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  await drawn.press({ key: "e1" });
  await drawn.unmount();
  await $.command.run(RUN);

  await $.prompt.submit({
    text: "<task-notification>build finished</task-notification>",
    wait: false,
    isMeta: true,
    origin: { kind: "task-notification" },
  });
  await ends($, PLAIN);
  expect(await hint($)).toContain("1 of 3");
  // The same round asked again keeps its answers too.
  await ends($, GRILLING);
  expect(await hint($)).toContain("1 of 3");
});

test("the row keeps what is drawn beneath it; the open form has the band to itself", async ($, on) => {
  world(on);
  await ends($, GRILLING);
  let drawn = await band($);
  expect(await drawn.find({ type: "Text", text: /engine/ })).toBeDefined();
  await drawn.unmount();
  drawn = await form($);
  expect(await drawn.find({ type: "Text", text: /engine/ })).toBeUndefined();
  await drawn.unmount();
});

test("a draft that crowds the form is set aside while it is open, and a second fill takes the first one's place", async ($, on) => {
  const draft = "and keep it short\nplease";
  const w = world(on, draft);
  await start($);
  await ends($, GRILLING);
  // The band has few rows here, as under a tall prompt box on a small terminal.
  const drawn = await $.ui.mount({
    ...BAND,
    props: { ...BAND.props, maxRows: 14 },
    surface: "terminal",
  });
  await drawn.press({ key: "answer" });
  expect(w.box).toBe("");
  await drawn.press({ key: "quit" });
  expect(w.box).toBe(draft);
  await drawn.press({ key: "answer" });
  await drawn.press({ key: "e1" });
  await drawn.press({ key: "review" });
  await drawn.press({ key: "fill" });
  expect(w.box).toBe(`Q1: B\n\n${draft}`);
  // Reopened, the reply and the draft are out of the way again.
  await drawn.press({ key: "answer" });
  expect(w.box).toBe("");
  await drawn.press({ key: "fill" });
  expect(w.box).toBe(`Q1: B\n\n${draft}`);
  await drawn.unmount();
});

test("a draft the form has room beside stays in the prompt", async ($, on) => {
  const w = world(on, "and keep it short\nplease");
  await start($);
  await ends($, GRILLING);
  const drawn = await band($);
  await drawn.press({ key: "answer" });
  expect(w.box).toBe("and keep it short\nplease");
  await drawn.unmount();
});

test("a pick asks for a note, Enter goes on, and the review fills the prompt", async ($, on) => {
  const w = world(on, "and keep it short");
  await ends($, GRILLING);
  const drawn = await band($);
  await drawn.press({ key: "answer" });
  // Q1: B, then its note; Enter there goes on.
  await drawn.press({ key: "e1" });
  expect(await drawn.find({ type: "Text", text: /^Should every focus default/ })).toBeDefined();
  await drawn.input({ key: "note-field", text: "but keep the flag" });
  // Q2 has a recommendation and no options: it is the first entry. Enter skips the note.
  expect((await drawn.find({ key: "e0" }))?.text).toContain("Yes:");
  await drawn.press({ key: "e0" });
  await drawn.input({ key: "note-field", text: "" });
  // Q3's write-in is a row like its options until it is picked; then it is a field.
  expect((await drawn.find({ key: "e2" }))?.text).toContain("Write your own answer");
  await drawn.press({ key: "e2" });
  await drawn.input({ key: "write-field", text: "drop it" });
  const reply = "Q1: B\n    Note: but keep the flag\nQ2: yes\nQ3: drop it";
  expect((await drawn.findAll({ type: "Text" })).some((t) => t.text === reply)).toBe(true);
  await drawn.press({ key: "fill" });
  // Filled, the form folds back to its row.
  expect(await drawn.find({ key: "answer" })).toBeDefined();
  await drawn.unmount();

  expect(w.box).toBe(`${reply}\n\nand keep it short`);
});

test("skip, back and forward move without answering; closing keeps the answers", async ($, on) => {
  world(on);
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  await drawn.press({ key: "skip" });
  await drawn.press({ key: "back" });
  expect(await drawn.find({ type: "Text", text: /^Should every focus default/ })).toBeDefined();
  await drawn.press({ key: "next" });
  await drawn.press({ key: "e0" });
  await drawn.input({ key: "note-field", text: "" });
  expect(await drawn.find({ type: "Text", text: /^What should happen to/ })).toBeDefined();
  await drawn.press({ key: "quit" });
  expect((await drawn.find({ key: "answer" }))?.text).toContain("1 of 3");
  await drawn.unmount();

  await $.prompt.submit({ text: "something else", wait: false, origin: { kind: "composer" } });
  expect(await hint($)).toBeUndefined();
});

test("the mouse alone answers: buttons keep what a field held, and a click on an option's detail picks it", async ($, on) => {
  const w = world(on);
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  expect(
    await drawn.find({ type: "Markdown", text: /Recommended:.*A\. A per-kind table/ }),
  ).toBeDefined();
  // The strip jumps to Q3, whose second option carries its detail inside the button.
  await drawn.press({ key: "q2" });
  expect((await drawn.find({ key: "e1" }))?.text).toContain("Scripts may still call it.");
  await drawn.press({ key: "e2" });
  await drawn.input({ key: "write-field", text: "drop it", kind: "change" });
  await drawn.press({ key: "next" });
  expect(await drawn.find({ type: "Text", text: /^Not answered: Q1, Q2\./ })).toBeDefined();
  await drawn.press({ key: "item0" });
  // A note typed and never entered is kept by the button that leaves.
  await drawn.press({ key: "e0" });
  await drawn.input({ key: "note-field", text: "for now", kind: "change" });
  await drawn.press({ key: "next" });
  expect(await drawn.find({ type: "Text", text: /^Lower the per-generator/ })).toBeDefined();
  await drawn.press({ key: "review" });
  await drawn.press({ key: "note" });
  await drawn.input({ key: "note-field", text: "thanks", kind: "change" });
  await drawn.press({ key: "fill" });
  await drawn.unmount();
  expect(w.box).toBe("Q1: A\n    Note: for now\nQ3: drop it\nOverall: thanks");
});

test("yes takes the recommendation, then its note", async ($, on) => {
  world(on);
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  await drawn.press({ key: "yes" });
  expect((await drawn.find({ key: "e0" }))?.text).toContain("✓");
  await drawn.input({ key: "note-field", text: "" });
  expect(await drawn.find({ type: "Text", text: /^Lower the per-generator/ })).toBeDefined();
  // Q3 recommends nothing, so it offers no yes.
  await drawn.press({ key: "next" });
  expect(await drawn.find({ key: "yes" })).toBeUndefined();
  await drawn.unmount();
});

test("several options of one question make one answer", async ($, on) => {
  world(on);
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  await drawn.press({ key: "multi" });
  await drawn.press({ key: "e0" });
  await drawn.press({ key: "e2" });
  expect(await drawn.find({ type: "Text", text: /^Should every focus default/ })).toBeDefined();
  expect((await drawn.find({ key: "e2" }))?.text).toContain("[x]");
  expect((await drawn.find({ key: "e1" }))?.text).toContain("[ ]");
  await drawn.press({ key: "next" });
  // Q2 has nothing to pick several of.
  expect(await drawn.find({ key: "multi" })).toBeUndefined();
  await drawn.press({ key: "review" });
  expect((await drawn.findAll({ type: "Text" })).some((t) => t.text === "Q1: A, C")).toBe(true);
  await drawn.unmount();
});

test("a long body gives way to the entries when the band is short", async ($, on) => {
  world(on);
  await start($);
  await ends($, LONG);
  await $.command.run(RUN);
  const short = await $.ui.mount({
    ...BAND,
    props: { ...BAND.props, maxRows: 16 },
    surface: "terminal",
  });
  expect(await short.find({ type: "Text", text: /^… more above$/ })).toBeDefined();
  expect(await short.find({ key: "e1" })).toBeDefined();
  await short.unmount();
  const tall = await band($);
  expect(await tall.find({ type: "Text", text: /^… more above$/ })).toBeUndefined();
  await tall.unmount();
});

test("a pick list routes each item to its own next step", async ($, on) => {
  const w = world(on);
  await start($);
  await ends($, MINE);
  expect(await hint($)).toContain("Pick from 2 items");
  await $.command.run(RUN);
  const drawn = await $.ui.mount({ ...BAND, surface: "desktop" });
  await drawn.press({ key: "e0" });
  await drawn.input({ key: "note-field", text: "" });
  await drawn.press({ key: "e1" });
  await drawn.input({ key: "note-field", text: "" });
  await drawn.press({ key: "fill" });
  await drawn.unmount();
  expect(w.box).toBe("do 1\n2 → /grill-me");
});

test("a new round replaces the one before it, answers and all", async ($, on) => {
  world(on);
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  await drawn.press({ key: "e1" });
  await drawn.unmount();
  await ends($, MINE);
  expect(await hint($)).toContain("Pick from 2 items");
  expect(await hint($)).toContain("0 of 2");
});

test("nothing runs or is read outside the session: the form needs no hub", async ($, on) => {
  world(on);
  const reached: string[] = [];
  on("process.run", (_, e) => {
    reached.push(e.argv.join(" "));
    throw new Error("no process");
  });
  on("fs.stat", () => {
    reached.push("fs.stat");
    throw new Error("no file");
  });
  await start($);
  await ends($, GRILLING);
  const drawn = await form($);
  await drawn.press({ key: "e1" });
  await drawn.unmount();
  await $.command.run(RUN);
  expect(await hint($)).toContain("1 of 3");
  expect(reached).toEqual([]);
});
