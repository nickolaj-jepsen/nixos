import type { On } from "claude-code";
import { expect, test } from "claude-code/testing";
import type { Engine } from "claude-code/testing";

import { grillingRound, mineSummary, plainList } from "./fixtures";

const BAND = {
  plugin: "answer",
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

const PANE = {
  plugin: "answer",
  component: "Pane",
  requestId: "answer",
  props: {
    title: "Answer",
    isFocused: true,
    bodyColumns: 60,
    placement: "dock",
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const;

const RUN = {
  command: "answer",
  args: "",
  origin: { kind: "composer" },
  presentation: { isFullscreen: true, columns: 160 },
} as const;

type World = { box: string; isOpen: boolean };

/** Stands in for the engine: the prompt box, the one pane and the band beneath. */
function world(on: On, draft = ""): World {
  const w: World = { box: draft, isOpen: false };
  on("prompt.read", () => ({ value: { text: w.box, cursor: w.box.length } }));
  on("prompt.fill", (_, e) => {
    w.box = e.text;
    return { isFilled: true };
  });
  on("prompt.submit", (_, e) => ({ text: e.text }));
  on("turn.complete", () => ({ text: "" }));
  on("command.register", () => ({ value: { command: "answer" } }));
  on("session.start", (_, e) => ({ cwd: e.cwd }));
  on("ui.open", () => {
    w.isOpen = true;
    return { value: { isPlaced: true } };
  });
  on("ui.close", () => {
    w.isOpen = false;
    return { value: undefined };
  });
  on("ui.panes", () => ({
    value: w.isOpen
      ? [{ id: "answer", title: "Answer", isShown: true, isFocused: true, isPlaced: true }]
      : [],
  }));
  on("ui.focus", () => ({}));
  on("ui.toast", () => ({ value: undefined }));
  on("ui.render", ($, e) => {
    const { Text } = $.ui.resolve(e);
    return <Text>engine</Text>;
  });
  return w;
}

const ends = ($: Engine, answer: string) =>
  $.turn.complete({ answer, reason: "answer", turnId: "t", durationMs: 1, isAborted: false });

const hint = async ($: Engine) => {
  const band = await $.ui.mount({ ...BAND, surface: "terminal" });
  const found = await band.find({ key: "answer" });
  await band.unmount();
  return found?.text;
};

test("a turn that ends on questions offers the form; one that doesn't, nothing", async ($, on) => {
  world(on);
  await ends($, grillingRound);
  expect(await hint($)).toContain("Answer 3 questions");
  await ends($, plainList);
  expect(await hint($)).toBeUndefined();
});

test("the band keeps what is drawn beneath it", async ($, on) => {
  world(on);
  await ends($, grillingRound);
  const band = await $.ui.mount({ ...BAND, surface: "terminal" });
  expect(await band.find({ type: "Text", text: /engine/ })).toBeDefined();
  await band.unmount();
});

test("a pick asks for a note, Enter goes on, and the review fills the prompt", async ($, on) => {
  const w = world(on, "and keep it short");
  await ends($, grillingRound);
  const band = await $.ui.mount({ ...BAND, surface: "terminal" });
  await band.press({ key: "answer" });
  await band.unmount();
  expect(w.isOpen).toBe(true);

  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  // Q1: B, with a note.
  await pane.press({ key: "e1" });
  await pane.input({ key: "field", text: "but keep the flag" });
  // Q2 has a recommendation and no options: it is the first entry. Enter skips the note.
  expect((await pane.find({ key: "e0" }))?.text).toContain("Yes:");
  await pane.press({ key: "e0" });
  await pane.input({ key: "field", text: "" });
  // Q3's write-in follows its two options.
  await pane.press({ key: "e2" });
  await pane.input({ key: "field", text: "drop it" });
  expect(
    await pane.find({ type: "Text", text: /^Q1: B — but keep the flag\nQ2: yes\nQ3: drop it$/ }),
  ).toBeDefined();
  await pane.press({ key: "fill" });
  await pane.unmount();

  expect(w.box).toBe("Q1: B — but keep the flag\nQ2: yes\nQ3: drop it\n\nand keep it short");
  expect(w.isOpen).toBe(false);
});

test("skip, back and forward move without answering; closing keeps the answers", async ($, on) => {
  world(on);
  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await ends($, grillingRound);
  await $.command.run(RUN);
  const pane = await $.ui.mount({ ...PANE, surface: "terminal" });
  await pane.press({ key: "skip" });
  await pane.press({ key: "back" });
  expect(await pane.find({ type: "Text", text: /^Q1 · 1 of 3$/ })).toBeDefined();
  await pane.press({ key: "forward" });
  await pane.press({ key: "e0" });
  await pane.input({ key: "field", text: "" });
  expect(await pane.find({ type: "Text", text: /^Q3 · 3 of 3$/ })).toBeDefined();
  await pane.unmount();
  await $.command.run(RUN);
  expect(await hint($)).toContain("1 answered");

  await $.prompt.submit({ text: "something else", wait: false, origin: { kind: "composer" } });
  expect(await hint($)).toBeUndefined();
});

test("a pick list routes each item to its own next step", async ($, on) => {
  const w = world(on);
  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await ends($, mineSummary);
  expect(await hint($)).toContain("Pick from 2 items");
  await $.command.run(RUN);
  const pane = await $.ui.mount({ ...PANE, surface: "desktop" });
  await pane.press({ key: "e0" });
  await pane.input({ key: "field", text: "" });
  await pane.press({ key: "e1" });
  await pane.input({ key: "field", text: "" });
  await pane.press({ key: "fill" });
  await pane.unmount();
  expect(w.box).toBe("do 1\n2 → /grill-me");
});
