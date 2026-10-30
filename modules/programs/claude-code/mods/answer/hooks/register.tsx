import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { Current } from "../types";
import {
  type Answer,
  type Entry,
  entries,
  type Form,
  go,
  isChosen,
  isReview,
  type Item,
  newDraft,
  parse,
  placeReply,
  record,
  reply,
  said,
  setNote,
  skip,
  startEntry,
} from "./core";

const PANE = "answer";
// Borrowed: mods can't define keybinding actions, and the engine handles this
// one only while the diff panel is open. A key bound to it in keybindings.json
// presses the band's button from the prompt.
const ACTION = "app:cycleDiffBase";
const CHORD = "alt+a";
// The dock is held to 45% of the terminal; ask for all of it.
const COLUMNS = 120;
const FIELD = "field";

// Change the tag when Current changes shape: a reload keeps what the old code stored.
const current = atom({ plugin: "answer", key: "current" } as const, null, { shape: "current-3" });

const edit = ($: EngineInterface, fn: (c: Current) => Current) =>
  update($, current, (c) => (c ? fn(c) : c));

const isOpen = async ($: EngineInterface) => (await $.ui.panes()).some((p) => p.id === PANE);

const title = (form: Form) =>
  form.kind === "round"
    ? `Answer ${form.items.length} question${form.items.length === 1 ? "" : "s"}`
    : `Pick from ${form.items.length} item${form.items.length === 1 ? "" : "s"}`;

/** Moves the focus ring; cosmetic, so a ring that can't move leaves the keys working. */
const focus = ($: EngineInterface, key: string) =>
  $.ui.focus({ requestId: PANE, key }).catch(() => undefined);

/** Shows another item, its ring on the answer or the recommendation. */
async function move($: EngineInterface, step: (form: Form, c: Current) => Current["draft"]) {
  const c = await edit($, (cur) => ({ ...cur, draft: step(cur.form, cur), editing: null }));
  const item = c?.form.items[c.draft.step];
  await focus($, item && c ? `e${startEntry(item, c.draft.answers[c.draft.step])}` : "fill");
}

/** Edits a field and hands it the ring: the write-in, or a note after an answer. */
async function startEditing($: EngineInterface, editing: "text" | "note") {
  await edit($, (c) => ({ ...c, editing }));
  await focus($, FIELD);
}

/** A picked entry: an answer, then its note; a write-in opens its field instead. */
async function choose($: EngineInterface, entry: Entry) {
  if (entry.kind === "write") return startEditing($, "text");
  const value: Answer = entry.kind === "accept" ? { kind: "accept" } : entry;
  await edit($, (c) => ({ ...c, draft: record(c.form, c.draft, value) }));
  await startEditing($, "note");
}

/**
 * Opens the form. Called before any other await of a press: an open that comes
 * after the press has returned counts as the plugin's own, and waits undrawn
 * below 144 columns.
 */
async function open($: EngineInterface, c: Current) {
  const opened = await $.ui.open({
    id: PANE,
    title: title(c.form),
    focus: true,
    closeOnEscape: true,
    holdToasts: true,
    columns: COLUMNS,
  });
  if (!opened.isPlaced) $.ui.toast(`The answer form can't show yet: ${opened.reason}`);
}

/** `/answer`: opens the form, or closes it when it is already up. */
async function toggle($: EngineInterface) {
  if (await isOpen($)) return $.ui.close({ id: PANE });
  const c = await read($, current);
  if (!c) {
    $.ui.toast("Nothing to answer: the last turn asked no questions.");
    return;
  }
  await open($, c);
}

/** Writes the reply into the prompt, above any draft, for the person to send. */
async function fill($: EngineInterface) {
  const c = await read($, current);
  const text = c ? reply(c.form, c.draft) : "";
  if (!text) {
    $.ui.toast("Nothing answered yet.");
    return;
  }
  const box = await $.prompt.read();
  await $.prompt.fill({ text: placeReply(box.text, text), mode: "replace" });
  await $.ui.close({ id: PANE });
}

/** An entry's words: an option with its letter, the recommendation, or the write-in. */
function entryText(form: Form, item: Item, entry: Entry): string {
  if (entry.kind === "write")
    return form.kind === "round" ? "Write your own answer" : "Something else";
  if (entry.kind === "accept") return `Yes: ${item.recommended || "as recommended"}`;
  const o = item.options[entry.index];
  return form.kind === "round" ? `${o?.key}. ${o?.text}` : (o?.text ?? "");
}

/** What an item's answer reads as on the review: the option's words, not just its key. */
function shown(item: Item, a: Answer | null): string {
  if (!a) return "skipped";
  if (a.kind === "text") return `"${a.text}"`;
  const index = a.kind === "option" ? a.index : item.recommendedOption;
  if (index === undefined) return "yes";
  return `${said(item, a)}: ${item.options[index]?.text ?? ""}`;
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    await $.command
      .register({
        name: "answer",
        description: "Answer the questions or pick list the last turn ended on, from a form",
        immediate: true,
      })
      .catch((error) =>
        $.ui.log(`answer: /answer not registered: ${String(error)}`, { to: "debug" }),
      );
    return next(e);
  });

  on("turn.complete", async ($, e, next) => {
    if (e.agentId === undefined && e.reason === "answer") {
      const form = parse(e.answer);
      await update($, current, () =>
        form ? { form, draft: newDraft(form), editing: null } : null,
      );
      if (!form && (await isOpen($))) await $.ui.close({ id: PANE });
    }
    return next(e);
  });

  // Anything sent answers the round, or moves past it.
  on("prompt.submit", async ($, e, next) => {
    if (await read($, current)) {
      await update($, current, () => null);
      if (await isOpen($)) await $.ui.close({ id: PANE });
    }
    return next(e);
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));

  on("command.run", { command: "answer" }, async ($) => {
    await toggle($);
    return { text: "" };
  });

  // Closing keeps the answers; only the next turn or a send drops them.
  on("ui.close", { id: PANE }, async ($, e, next) => {
    await edit($, (c) => ({ ...c, editing: null }));
    return next(e);
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    const below = await next(e);
    if (e.props.hasSurvey) return below;
    const c = await read($, current);
    if (!c) return below;
    const { Box, Button, Text } = $.ui.resolve(e);
    const done = c.draft.answers.filter(Boolean).length;
    // Kept mounted while there is a form: the key bound to ACTION reaches only a mounted Button.
    return (
      <Box flexDirection="column">
        {below}
        <Button key="answer" plain action={ACTION} onPress={() => void open($, c)}>
          {title(c.form)}
          <Text dimColor>{`${done ? ` · ${done} answered` : ""} · ${CHORD} or /answer`}</Text>
        </Button>
      </Box>
    );
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    const els = $.ui.resolve(e);
    const { Box, Text, Button, Markdown } = els;
    const c = await read($, current);
    if (!c) return <Text dimColor>Nothing to answer.</Text>;
    const { form, draft, editing } = c;
    const field = (placeholder: string, value: string, onSubmit: (text: string) => void) =>
      "Input" in els ? (
        <els.Input
          key={FIELD}
          autoFocus
          placeholder={placeholder}
          value={value}
          submitLabel="next"
          onSubmit={(text) => onSubmit(text)}
        />
      ) : null;
    const nav = (keys: [string, string, () => unknown][]) => (
      <Box columnGap={2} flexWrap="wrap">
        {keys.map(([hotkey, label, press]) => (
          <Button key={label} hotkey={hotkey} label={label} onPress={() => void press()} />
        ))}
      </Box>
    );
    const back = () => move($, (f, cur) => go(f, cur.draft, cur.draft.step - 1));

    if (isReview(form, draft)) {
      const text = reply(form, draft);
      const saveNote = async (t: string) => {
        await edit($, (cur) => ({ ...cur, draft: setNote(cur.form, cur.draft, t), editing: null }));
        await focus($, "fill");
      };
      return (
        <Box flexDirection="column" rowGap={1}>
          <Text weight="semibold">Review</Text>
          <Box flexDirection="column">
            {form.items.map((item, i) => (
              <Button
                key={`item${i}`}
                plain
                hotkey={i < 9 ? String(i + 1) : undefined}
                onPress={() => void move($, (f, cur) => go(f, cur.draft, i))}
              >
                {`${item.label}  `}
                <Text dimColor={!draft.answers[i]}>{shown(item, draft.answers[i] ?? null)}</Text>
                {draft.notes[i] ? <Text dimColor>{` — ${draft.notes[i]}`}</Text> : null}
              </Button>
            ))}
          </Box>
          {editing === "note" ? (
            field("A note on the whole round, Enter to keep", draft.note, (t) => void saveNote(t))
          ) : draft.note ? (
            <Text>{`Note: ${draft.note}`}</Text>
          ) : null}
          <Box flexDirection="column">
            <Text dimColor>The reply:</Text>
            <Text>{text || "(nothing answered yet)"}</Text>
          </Box>
          <Button
            key="fill"
            variant="primary"
            autoFocus={editing ? undefined : true}
            label="fill the prompt"
            onPress={() => void fill($)}
          />
          {nav([
            ["n", "note", () => startEditing($, "note")],
            ["b", "back", back],
          ])}
          <Text dimColor>1-9 revisits · Esc closes, answers kept</Text>
        </Box>
      );
    }

    const item = form.items[draft.step];
    if (!item) return <Text dimColor>Nothing to answer.</Text>;
    const chosen = draft.answers[draft.step];
    const note = draft.notes[draft.step] ?? "";
    const list = entries(item);
    const start = startEntry(item, chosen);
    const saveText = async (t: string) => {
      await edit($, (cur) => ({
        ...cur,
        draft: record(cur.form, cur.draft, { kind: "text", text: t }),
      }));
      await move($, (f, cur) => go(f, cur.draft, cur.draft.step + 1));
    };
    return (
      <Box flexDirection="column" rowGap={1}>
        <Text dimColor>{`${item.label} · ${draft.step + 1} of ${form.items.length}`}</Text>
        <Text weight="semibold">{item.title}</Text>
        {item.body ? <Markdown key="body" text={item.body} /> : null}
        <Box flexDirection="column">
          {list.map((entry, k) => {
            const isRec = entry.kind === "option" && entry.index === item.recommendedOption;
            const detail = entry.kind === "option" ? item.options[entry.index]?.detail : "";
            return (
              <Box key={`row${k}`} flexDirection="column">
                <Button
                  key={`e${k}`}
                  plain
                  hotkey={k < 9 ? String(k + 1) : undefined}
                  autoFocus={!editing && k === start ? true : undefined}
                  onPress={() => void choose($, entry)}
                >
                  {entryText(form, item, entry)}
                  {isRec ? <Text dimColor> (recommended)</Text> : null}
                  {isChosen(item, chosen, entry) ? <Text color="success"> ✓</Text> : null}
                </Button>
                {detail ? <Text dimColor>{`   ${detail.replace(/\n/g, "\n   ")}`}</Text> : null}
              </Box>
            );
          })}
        </Box>
        {chosen?.kind === "text" && editing !== "text" ? (
          <Text>{`Your answer: ${chosen.text}`}</Text>
        ) : null}
        {editing === "text"
          ? field(
              "Your answer, Enter to save",
              chosen?.kind === "text" ? chosen.text : "",
              (t) => void saveText(t),
            )
          : null}
        {editing === "note" ? (
          field(
            "A note, or Enter to go on",
            note,
            (t) => void move($, (f, cur) => go(f, setNote(f, cur.draft, t), cur.draft.step + 1)),
          )
        ) : note ? (
          <Text dimColor>{`Note: ${note}`}</Text>
        ) : null}
        {nav([
          ["b", "back", back],
          ["f", "forward", () => move($, (f, cur) => go(f, cur.draft, cur.draft.step + 1))],
          ["s", "skip", () => move($, (f, cur) => skip(f, cur.draft))],
          ["r", "review", () => move($, (f, cur) => go(f, cur.draft, f.items.length))],
        ])}
        <Text dimColor>1-9 or Enter answers · ↑↓ or Tab moves · Esc closes, answers kept</Text>
      </Box>
    );
  });
};
