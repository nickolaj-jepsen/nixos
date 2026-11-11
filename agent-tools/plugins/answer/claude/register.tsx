import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import { formId, offer, parse, startLines, step as stepForm, view as viewOf } from "../core/forms";
import type { Action, Current, Entry, Held, Item, Split, View } from "../types";

// The two fields, each drawn while it is being typed in.
const WRITE = "write";
const NOTE = "note";
/** A field's address; a key row button is already called `note`. */
const keyOf = (field: typeof WRITE | typeof NOTE) => `${field}-field`;
// What the row says focuses the band; the binding itself is in keybindings.json.
const CHORD = "alt+a";
// A row kept free for wraps guessed short.
const SLACK_ROWS = 1;
// A row left to a mod whose band hook sits above this one, which can't be seen from here: a
// form of all the band's rows would push its own keys out of view.
const RESERVED_ROWS = 1;

// Change the tag when Current changes shape: a reload keeps what the old code stored.
const current = atom({ plugin: "answer", key: "current" } as const, null, { shape: "current-9" });

/**
 * The `scrollTranscript` option: a question's body is read in the transcript, which scrolls
 * to it, and not in the form. Off, the form shows the body and the transcript is left alone.
 */
let isInTranscript = false;

// Kept in the session, not the module: a reload must still know the rows it placed.
const splits = atom({ plugin: "answer", key: "splits" } as const, [] as Split[], {
  shape: "splits-1",
});

/** Origins that are the person speaking; a task's notification or a peer's message isn't. */
const PERSON = new Set<string>(["composer", "bridge", "sdk", "slack-ping"]);

/**
 * What a field holds that Enter hasn't saved, null while untouched. A button that leaves
 * the item saves it first: a click must not lose what was typed.
 */
let typed: { field: typeof WRITE | typeof NOTE; text: string } | null = null;
/** The band's id for `$.ui.focus`, known once it has drawn. */
let band: string | undefined;
/** The band's rows and columns when it last drew: what the prompt box leaves it. */
let room: { rows: number; columns: number } | undefined;
/** When a note was last asked for; the click that picked its answer moves the ring just after. */
let askedAt = 0;
const CLICK_MS = 500;
// How long a pick waits for the click after it, and how often it looks.
const SECOND_CLICK_MS = 600;
const LOOK_MS = 100;
/** The transcript row that holds the form, by the form's id. */
let row: { form: string; requestId: string } | null = null;
/** The newest split of a form: the same round asked again is another message with rows of its own. */
const splitOf = (all: Split[], form: string) => all.findLast((split) => split.form === form);
const lasted = (ms: number) => {
  const seconds = Math.round(ms / 1000);
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
};
const linesOf = (text: string) => text.replace(/\r\n?/g, "\n").split("\n");
/** The form each transcript row's text holds, null for none, by the row's id and its text's length. */
const asked = new Map<string, { length: number; form: string | null }>();

/** How many rows a text takes at a width, each line wrapped; a guess, since words wrap early. */
const rowsOf = (text: string, columns: number) =>
  text.split("\n").reduce((n, line) => n + Math.max(1, Math.ceil(line.length / columns)), 0);

const complain = ($: EngineInterface, error: unknown) =>
  $.ui.log(`answer: ${String(error)}`, { to: "debug" });

/** What is held over what was shown: the same item keeps its field and mode, the same form stays open. */
const over = (c: Current | null, held: Held): Current => {
  const view = viewOf(held.form, held.draft);
  const isSameForm = c?.view.id === view.id;
  const isSameItem = isSameForm && c?.view.step === view.step;
  return {
    held,
    view,
    editing: isSameItem ? (c?.editing ?? null) : null,
    several: isSameItem ? (c?.several ?? null) : null,
    isOpen: isSameForm ? (c?.isOpen ?? false) : false,
    stash: isSameForm ? (c?.stash ?? null) : null,
    filled: isSameForm ? (c?.filled ?? null) : null,
  };
};

const edit = ($: EngineInterface, fn: (c: Current) => Current) =>
  update($, current, (c) => (c ? fn(c) : c));

/** Whether picks toggle on the shown item: as the person set it, else as its answer already is. */
const isSeveral = (c: Current) => c.several ?? c.view.item?.isSeveral ?? false;

/** Moves the focus ring; the keyboard is the person's to give, so a band without it is left be. */
const focus = async ($: EngineInterface, key: string) =>
  band ? $.ui.focus({ requestId: band, key }).catch(() => undefined) : undefined;

/** The ring's place on what is shown: the answer or the recommendation, or the review's button. */
const home = (view: View) => (view.item ? `e${view.item.start}` : "fill");

/**
 * Scrolls the transcript to the shown question's row, or with none of its own to the message.
 * The engine does that only inside the person's own press or command, so a handler hands
 * its promise back for the engine to wait on: one let go with `void` is refused here.
 */
async function reveal($: EngineInterface, view: View) {
  if (!isInTranscript || !view.item) return;
  const own =
    view.step > 0
      ? splitOf(await read($, splits), view.id)?.rows[view.step - 1]?.requestId
      : undefined;
  const requestId = own ?? (row?.form === view.id ? row.requestId : undefined);
  if (requestId) await $.ui.scroll({ to: { requestId }, block: "start" }).catch(() => undefined);
}

/**
 * Gives each question past the first its own row at the transcript's end, right under the
 * message, which then draws only up to them: the engine scrolls to a row's top, never into it.
 */
async function splitUp($: EngineInterface, text: string, view: View, durationMs: number | null) {
  if (!isInTranscript || view.kind !== "round") return;
  const lines = linesOf(text);
  const starts = startLines(text);
  if (starts.length < 2) return;
  const rows: Split["rows"] = [];
  const stamp = await $.clock.now();
  for (let i = 1; i < starts.length; i++) {
    const id = `${view.id}-${stamp}-${i}`;
    const placed = await $.ui.place({ id });
    // With no surface to draw them the message stays whole.
    if (!placed.isPlaced) return;
    const part = lines.slice(starts[i], starts[i + 1]);
    rows.push({ id, requestId: placed.requestId, text: part.join("\n").trim() });
  }
  const head = lines.slice(0, starts[1]).join("\n").trimEnd();
  await update($, splits, (all) => [...all, { form: view.id, head, rows, durationMs }]);
}

/**
 * Places the shown round's rows again under the ids they had: after a reload they still
 * stand and only answer with their place. A round that can't have them all gets its
 * message back whole.
 */
async function restore($: EngineInterface) {
  const c = await read($, current);
  if (!isInTranscript || !c) return;
  const split = splitOf(await read($, splits), c.view.id);
  if (!split) return;
  const rows: Split["rows"] = [];
  for (const row of split.rows) {
    const placed = await $.ui.place({ id: row.id }).catch(() => undefined);
    if (placed?.isPlaced) rows.push({ ...row, requestId: placed.requestId });
  }
  const isWhole = rows.length === split.rows.length;
  await update($, splits, (all) =>
    all.flatMap((was) => (was !== split ? [was] : isWhole ? [{ ...was, rows }] : [])),
  );
}

/** One step of the draft, and what it now shows; null with no form to step. */
async function step($: EngineInterface, action: Action): Promise<View | null> {
  typed = null;
  // Aimed at the form that was showing, so a round that arrived meanwhile is left as it is.
  const shown = (await read($, current))?.view.id;
  const now = await update($, current, (was) =>
    was ? { ...over(was, stepForm(was.held, action, shown)), editing: null } : was,
  );
  return now?.view ?? null;
}

/** Takes a step and puts the ring where the new screen starts. */
async function move($: EngineInterface, action: Action) {
  const view = await step($, action);
  if (!view) return;
  await focus($, home(view));
  await reveal($, view);
}

/** Saves a field's typing as Enter there would; false when it couldn't be saved. */
async function keepTyped($: EngineInterface): Promise<boolean> {
  const held = typed;
  if (!held) return true;
  return Boolean(await step($, { do: held.field, text: held.text }));
}

/** Leaves the shown item for another by a button, keeping what a field held. */
async function leave($: EngineInterface, to: (shown: number) => Action) {
  const c = await read($, current);
  if (c && (await keepTyped($))) await move($, to(c.view.step));
}

/** Opens a field and hands it the ring: a note under its answer, or the write-in. */
async function ask($: EngineInterface, editing: typeof WRITE | typeof NOTE) {
  typed = null;
  await edit($, (c) => ({ ...c, editing }));
  if (editing === NOTE) askedAt = await $.clock.now();
  // A click is what gives the band the keys, and it may not have them yet: ask again, briefly.
  for (let tries = 0; tries < 4; tries++) {
    const moved = await focus($, keyOf(editing));
    if (!moved?.deny) return;
    await $.clock.sleep(60);
  }
}

/** Enter in the note: kept, and an answered question goes on to the next one unanswered. */
async function keepNote($: EngineInterface, text: string) {
  const view = await step($, { do: "note", text });
  if (!view) return;
  if (view.item?.entries.some((entry) => entry.isChosen)) await move($, { do: "next" });
  else await focus($, home(view));
}

/** A picked entry: the answer, then its note; one of several stays; the write-in opens its field. */
async function choose($: EngineInterface, entry: Entry, index: number) {
  if (entry.kind === "write") return ask($, WRITE);
  const c = await read($, current);
  if (!c) return;
  // A note being typed is this question's, so it is kept whichever answer is picked.
  if (typed?.field === NOTE && !(await keepTyped($))) return;
  if (isSeveral(c)) {
    if (await step($, { do: "toggle", entry: index })) await focus($, `e${index}`);
    return;
  }
  const selected = (await $.ui.selection().catch(() => undefined))?.text;
  if (!(await step($, { do: "pick", entry: index }))) return;
  await ask($, NOTE);
  await goOnSecondClick($, c.view, selected).catch(() => undefined);
}

/**
 * A double click on an answer goes on to the next question. The second click never reaches
 * the Button: the terminal takes it to select the word under it, and the rows may have
 * moved under the pointer by then. So a pick looks, briefly, for a selection made since,
 * outside the transcript. One of the same word as the last selection can't be told from it.
 */
async function goOnSecondClick($: EngineInterface, picked: View, before?: string) {
  for (let waited = 0; waited < SECOND_CLICK_MS; waited += LOOK_MS) {
    await $.clock.sleep(LOOK_MS);
    const now = await $.ui.selection().catch(() => undefined);
    if (!now?.text.trim() || now.requestId || now.text === before) continue;
    const c = await read($, current);
    // Only from where the pick left it: not once the person has typed or moved on.
    if (c?.isOpen && c.view.id === picked.id && c.view.step === picked.step && typed === null)
      await move($, { do: "go", step: picked.step + 1 });
    return;
  }
}

/** Takes the question's recommendation, whatever it names, then its note. */
async function accept($: EngineInterface) {
  if (await step($, { do: "accept" })) await ask($, NOTE);
}

/**
 * Opens the form. The band shares its half of the screen with the prompt box, so a draft of
 * several lines that leaves the form short of its height is set aside until it folds.
 */
async function open($: EngineInterface) {
  const c = await read($, current);
  if (!c) return;
  const box = await $.prompt.read();
  const isCramped =
    room !== undefined &&
    room.rows - RESERVED_ROWS < heightOf(c, room.columns) &&
    rowsOf(box.text, room.columns) >= 2;
  const isTaken = isCramped && (await $.prompt.fill({ text: "", mode: "replace" })).isFilled;
  await edit($, (was) => ({ ...was, isOpen: true, stash: isTaken ? box.text : was.stash }));
  await focus($, home(c.view));
  await reveal($, c.view);
}

/** The reply above what the person had typed, never over it. */
const placeReply = (draft: string, text: string) => (draft.trim() ? `${text}\n\n${draft}` : text);

/** What the person typed themselves: the prompt's text less the reply an earlier fill put on it. */
const ownDraft = (text: string, filled: string | null) =>
  filled && text.startsWith(filled) ? text.slice(filled.length).replace(/^\n+/, "") : text;

/** Folds the form back to its row, the answers kept, and hands the prompt its text back. */
async function close($: EngineInterface) {
  typed = null;
  const c = await read($, current);
  if (!c) return;
  if (c.stash !== null) {
    const box = await $.prompt.read();
    await $.prompt.fill({ text: placeReply(box.text, c.stash), mode: "replace" });
  }
  await edit($, (was) => ({ ...was, isOpen: false, editing: null, stash: null }));
}

/**
 * A user message the person didn't write: a slash command's record, another session's
 * message or a background task's news. The transcript's messages carry no origin, so
 * this goes by the wrapper each arrives in.
 */
const isNotPerson = (text: string) =>
  /^\s*<(command-|local-command-|task-notification)/.test(text) ||
  text.includes("<cross-session-message ");

/**
 * The round a resumed session came back to. `turn.complete` fired in the process before
 * this one, so the round is read from the transcript: the newest reply that holds one,
 * past any turn something other than the person started, as a live session keeps a round
 * through those. One the person has spoken after is left alone. Answers with the message
 * it took the round from.
 */
async function recover($: EngineInterface): Promise<string | undefined> {
  if (await read($, current)) return undefined;
  const messages = await $.session.messages();
  if (!Array.isArray(messages)) return undefined;
  for (const message of [...messages].reverse()) {
    if (message.role === "assistant") {
      const held = message.text ? offer(null, message.text) : null;
      if (!held) continue;
      await update($, current, (c) => c ?? over(null, held));
      return message.text;
    }
    if (!message.toolResults?.length && !isNotPerson(message.text)) return undefined;
  }
  return undefined;
}

/** `/answer`: opens the form, or folds it when it is already up. */
async function toggle($: EngineInterface) {
  await recover($).catch((error) => complain($, error));
  const c = await read($, current);
  if (!c) {
    $.ui.toast("Nothing to answer: the last turn asked no questions.");
    return;
  }
  await (c.isOpen ? close($) : open($));
}

/** Writes the reply into the prompt for the person to send: above their draft, in place of an earlier fill. */
async function fill($: EngineInterface, text: string): Promise<boolean> {
  const c = await read($, current);
  const box = await $.prompt.read();
  const held = [c?.stash, box.text].filter(Boolean).join("\n\n");
  const { isFilled } = await $.prompt.fill({
    text: placeReply(ownDraft(held, c?.filled ?? null), text),
    mode: "replace",
  });
  if (isFilled) {
    typed = null;
    await edit($, (was) => ({ ...was, isOpen: false, editing: null, stash: null, filled: text }));
  }
  return isFilled;
}

/** The rows one question takes besides its body: its title, entries, recommendation, a note and the keys. */
function chromeRows(item: Item, columns: number) {
  const entries = item.entries.reduce(
    (n, entry) =>
      n +
      rowsOf(`1: ${entry.text} (recommended) ✓`, columns) +
      (entry.detail ? rowsOf(entry.detail, columns - 3) : 0),
    0,
  );
  const said = item.recommended ? rowsOf(`Recommended: ${item.recommended}`, columns) + 1 : 0;
  // The divider, the gap under the title, a note, and the keys, wrapped when narrow.
  const fixed = 1 + 1 + 1 + (columns < 70 ? 2 : 1);
  return fixed + rowsOf(item.title, columns) + entries + said + SLACK_ROWS;
}

/** The body the form shows: none of it while it is read in the transcript. */
const bodyOf = (item: Item) => (isInTranscript ? "" : item.body);

/** How tall the form stands: as its tallest question, so going from one to the next moves nothing. */
const heightOf = (c: Current, columns: number) =>
  Math.max(
    ...c.held.form.items.map((_, step) => {
      const { item } = viewOf(c.held.form, { ...c.held.draft, step });
      if (!item) return 0;
      const body = bodyOf(item);
      return chromeRows(item, columns) + (body ? rowsOf(body, columns) : 0);
    }),
  );

/**
 * As much of a question's body as the form's rows leave once the title, entries and keys
 * are drawn: a digit only answers an entry on screen, so the body is what gives way.
 */
function fitBody(item: Item, rows: number, columns: number) {
  const body = bodyOf(item);
  const left = rows - chromeRows(item, columns);
  if (!body || rowsOf(body, columns) <= left) return { body, isCut: false };
  const kept: string[] = [];
  let used = 1;
  for (const line of body.split("\n")) {
    used += rowsOf(line, columns);
    if (used > left) break;
    kept.push(line);
  }
  // A code fence cut open would swallow what follows it.
  if (kept.filter((line) => /^\s*(```|~~~)/.test(line)).length % 2) kept.push("```");
  return { body: kept.join("\n").trim(), isCut: true };
}

export const register: Register = (on, options) => {
  isInTranscript = options.scrollTranscript === true;

  on("session.start", async ($, e, next) => {
    await $.command
      .register({
        name: "answer",
        description: "Answer the questions or pick list the last turn ended on, from a form",
        immediate: true,
      })
      .catch((error) => complain($, `/answer not registered: ${String(error)}`));
    const started = await next(e);
    // A resumed session has the round's message last in its transcript and none of the rows
    // an earlier process placed, so they are placed anew; a reload only finds its own again.
    // Never for a round already on screen without them: its rows would land under whatever
    // was printed since.
    const resumed = await recover($).catch((error) => complain($, error));
    const c = await read($, current);
    if (!isInTranscript) return started;
    if (resumed && c) await splitUp($, resumed, c.view, null).catch((error) => complain($, error));
    else await restore($).catch((error) => complain($, error));
    return started;
  });

  // Only a new round replaces the form; the person's send is what drops it. A turn a
  // background task woke ends on that task's news while the round still waits.
  on("turn.complete", async ($, e, next) => {
    if (e.agentId !== undefined || e.reason !== "answer") return next(e);
    const now = await update($, current, (c) => {
      const held = offer(c?.held ?? null, e.answer);
      return held ? over(c, held) : null;
    }).catch((error) => complain($, error));
    // Before the turn's closing row is drawn, so the questions sit right under their message.
    if (now && parse(e.answer))
      await splitUp($, e.answer, now.view, e.durationMs).catch((error) => complain($, error));
    return next(e);
  });

  // The person's own message answers the round, or moves past it.
  on("prompt.submit", async ($, e, next) => {
    const c = PERSON.has(e.origin.kind) ? await read($, current) : null;
    if (!c) return next(e);
    await update($, current, () => null);
    const sent = await next(e);
    // A draft set aside for the open form outlives the message sent past it.
    const draft = c.stash === null ? "" : ownDraft(c.stash, c.filled);
    if (draft) await $.prompt.fill({ text: draft, mode: "replace" }).catch(() => undefined);
    return sent;
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));

  on("command.run", { command: "answer" }, async ($) => {
    await toggle($);
    return { text: "" };
  });

  // Drawn in the band, not a pane: the surface docks every pane beside the transcript once
  // the terminal is wide, and a round of questions reads better over the prompt. Open, it
  // has the band to itself: what the mods beneath draw there waits until it folds.
  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    const below = await next(e);
    if (e.props.hasSurvey) return below;
    const c = await read($, current);
    if (!c) return below;
    band = e.requestId;
    room = { rows: e.props.maxRows, columns: e.props.bodyColumns };
    const els = $.ui.resolve(e);
    const { Box, Text, Button, Markdown } = els;
    const { view, editing } = c;

    if (!c.isOpen)
      return (
        <Box flexDirection="column">
          {below}
          <Button key="answer" plain autoFocus onPress={() => open($)}>
            {view.title}
            <Text dimColor>
              {` · ${view.answered} of ${view.count} · ${CHORD} then Enter, or /answer`}
            </Text>
          </Button>
        </Box>
      );

    const columns = e.props.bodyColumns;
    // A field with what it is led by: the mark that its text carries once it is kept.
    const field = (
      key: typeof WRITE | typeof NOTE,
      lead: JSX.Element,
      placeholder: string,
      value: string,
      submitLabel: string,
      onSubmit: (text: string) => unknown,
    ) =>
      "Input" in els ? (
        <Box>
          {lead}
          <els.Input
            key={keyOf(key)}
            autoFocus
            placeholder={placeholder}
            value={value}
            submitLabel={submitLabel}
            onInput={(text) => {
              typed = { field: key, text };
            }}
            onSubmit={(text) => onSubmit(text)}
          />
        </Box>
      ) : null;
    const noteLead = (
      <Text color="suggestion" italic>
        {"↳ "}
      </Text>
    );
    type Key = [hotkey: string, label: string, press: () => unknown, isLit?: boolean];
    // Plain, so each shows its key; dim but for the one worth pressing next.
    const keys = (shown: Key[]) => (
      <Box columnGap={3} flexWrap="wrap">
        {shown.map(([hotkey, label, press, isLit]) => (
          <Button
            key={label}
            plain
            dimColor={!isLit}
            hotkey={hotkey}
            label={label}
            onPress={() => press()}
          />
        ))}
      </Box>
    );
    const back = () => leave($, (shown) => ({ do: "go", step: shown - 1 }));
    const fold: Key = ["q", "quit", () => close($)];
    const unanswered = view.review.filter((row) => !row.isAnswered).map((row) => row.label);
    const panelRows = Math.min(e.props.maxRows - RESERVED_ROWS, heightOf(c, columns));
    // The rule that parts the form from the chat, and on it every question: which are
    // answered, which is shown, and a click to go to one.
    const stops = view.review.reduce((n, row) => n + row.label.length + 5, 0);
    const divider = (
      <Box columnGap={3} flexWrap="wrap">
        <Text dimColor>──</Text>
        {view.review.map((row, i) => (
          <Button
            key={`q${i}`}
            plain
            dimColor={i !== view.step}
            onPress={() => leave($, () => ({ do: "go", step: i }))}
          >
            {/* The mark leads, so it reads as its own label's. */}
            {row.isAnswered ? <Text color="success">✓ </Text> : <Text dimColor>○ </Text>}
            {row.label}
          </Button>
        ))}
        <Button
          key="review"
          plain
          dimColor={!view.isReview}
          hotkey="r"
          label="review"
          onPress={() => leave($, () => ({ do: "review" }))}
        />
        <Text dimColor>
          {"─".repeat(Math.max(0, columns - stops - "──   r: review   ".length - 1))}
        </Text>
      </Box>
    );

    if (!view.item) {
      const missing = `Not answered: ${unanswered.join(", ")}. Its row goes back to it.`;
      const reply = view.reply || "(nothing answered yet)";
      // The list, the note, the button and the keys always show. The reply only repeats the
      // list, so it gives way where the band is short: a taller tree scrolls, and the ring on
      // the button at its foot would take the first questions out of view.
      const listRows =
        view.review.reduce(
          (n, row) =>
            n +
            rowsOf(`1: ${row.label}  ${row.shown}`, columns) +
            (row.note ? rowsOf(`      ↳ ${row.note}`, columns) : 0),
          0,
        ) + (unanswered.length ? rowsOf(missing, columns) : 0);
      const fixedRows = 1 + listRows + 1 + (editing === NOTE ? 2 : 0) + 1 + (columns < 70 ? 2 : 1);
      const hasRoomForReply =
        fixedRows + 2 + rowsOf(reply, columns) + SLACK_ROWS <= e.props.maxRows - RESERVED_ROWS;
      return (
        <Box flexDirection="column" minHeight={panelRows} justifyContent="space-between">
          <Box flexDirection="column">
            {divider}
            <Box flexDirection="column" rowGap={1}>
              <Box flexDirection="column">
                {view.review.map((row, i) => (
                  <Box key={`row${i}`} flexDirection="column">
                    <Button
                      key={`item${i}`}
                      plain
                      hotkey={i < 9 ? String(i + 1) : undefined}
                      onPress={() => leave($, () => ({ do: "go", step: i }))}
                    >
                      {`${row.label}  `}
                      <Text dimColor={!row.isAnswered}>{row.shown}</Text>
                    </Button>
                    {row.note ? (
                      <Text color="suggestion" italic>{`      ↳ ${row.note}`}</Text>
                    ) : null}
                  </Box>
                ))}
                {unanswered.length ? <Text color="warning">{missing}</Text> : null}
              </Box>
              {hasRoomForReply ? (
                <Box flexDirection="column">
                  <Text dimColor>The reply:</Text>
                  <Text>{reply}</Text>
                </Box>
              ) : null}
              {editing === NOTE
                ? field(
                    NOTE,
                    noteLead,
                    "A note on the whole round, Enter to keep",
                    view.note,
                    "keep",
                    (t) => keepNote($, t),
                  )
                : null}
              <Button
                key="fill"
                variant="primary"
                autoFocus={editing ? undefined : true}
                label="fill the prompt"
                onPress={async () => {
                  const held = typed;
                  const kept = held ? await step($, { do: "note", text: held.text }) : view;
                  if (kept?.reply) await fill($, kept.reply);
                  else if (kept) $.ui.toast("Nothing answered yet.");
                }}
              />
            </Box>
          </Box>
          {keys([["h", "back", back], ["n", "note", () => ask($, NOTE)], fold])}
        </Box>
      );
    }

    const { item } = view;
    const several = isSeveral(c);
    const laid = fitBody(item, panelRows, columns);
    const forward = () => leave($, (shown) => ({ do: "go", step: shown + 1 }));
    // The write-in is always last.
    const writeIn = item.entries.length - 1;
    const chosen = item.entries.findIndex((row) => row.isChosen);
    // A note sits under the answer it is about; with none yet, under the entries.
    const noteAt = chosen >= 0 && chosen < writeIn ? chosen : writeIn - 1;
    // Yours, so it reads apart from the option's own dim lines above it, typed or kept.
    const note =
      editing === NOTE ? (
        <Box paddingLeft={3}>
          {field(
            NOTE,
            noteLead,
            "A note on this answer, or Enter to go on",
            item.note,
            "next",
            (t) => keepNote($, t),
          )}
        </Box>
      ) : item.note ? (
        <Box paddingLeft={3}>
          <Button key="note-line" plain onPress={() => ask($, NOTE)}>
            <Text color="suggestion" italic>{`↳ ${item.note}`}</Text>
          </Button>
        </Box>
      ) : null;
    const option = (row: Entry, k: number) => (
      <Button
        key={`e${k}`}
        plain
        // The write-in waits dim until it holds an answer.
        dimColor={row.kind === "write" && !item.written}
        hotkey={k < 9 ? String(k + 1) : undefined}
        autoFocus={!editing && k === item.start ? true : undefined}
        onPress={() => choose($, row, k)}
      >
        {several && row.kind === "option" ? (row.isChosen ? "[x] " : "[ ] ") : ""}
        {row.kind === "write" ? `✎ ${item.written || row.text}` : row.text}
        {row.isRecommended ? <Text dimColor> (recommended)</Text> : null}
        {row.isChosen && !(several && row.kind === "option") ? (
          <Text color="success"> ✓</Text>
        ) : null}
        {/* Inside the button, so a click on any of the option's lines picks it. */}
        {row.detail ? <Text dimColor>{`\n   ${row.detail.replace(/\n/g, "\n   ")}`}</Text> : null}
      </Button>
    );
    return (
      <Box flexDirection="column" minHeight={panelRows} justifyContent="space-between">
        <Box flexDirection="column">
          {divider}
          <Box flexDirection="column" rowGap={1}>
            <Box flexDirection="column">
              <Text weight="semibold">{item.title}</Text>
              {laid.body ? <Markdown key="body" text={laid.body} /> : null}
              {laid.isCut ? <Text dimColor>… more above</Text> : null}
            </Box>
            <Box flexDirection="column">
              {item.entries.slice(0, writeIn).map((row, k) => (
                <Box key={`row${k}`} flexDirection="column">
                  {option(row, k)}
                  {k === noteAt ? note : null}
                </Box>
              ))}
              {noteAt < 0 ? note : null}
              {/* The write-in is a row like the others until it is written in. */}
              {editing === WRITE
                ? field(
                    WRITE,
                    <Text>{"✎ "}</Text>,
                    "Write your own answer",
                    item.written,
                    "save",
                    (t) => move($, { do: "write", text: t }),
                  )
                : item.entries.slice(writeIn).map((row) => option(row, writeIn))}
            </Box>
            {item.recommended ? (
              <Markdown key="recommended" text={`**Recommended:** ${item.recommended}`} />
            ) : null}
          </Box>
        </Box>
        {/* Last, so the keys keep their row whatever the question holds. */}
        {keys([
          ["h", "back", back],
          ["l", "next", forward, chosen >= 0],
          ...(item.canAccept ? [["y", "yes", () => accept($), chosen < 0] as Key] : []),
          ["s", "skip", () => move($, { do: "skip" })],
          ["n", "note", () => ask($, NOTE)],
          ...(item.canSeveral
            ? [
                [
                  "m",
                  "multi",
                  () => edit($, (was) => ({ ...was, several: !isSeveral(was) })),
                  several,
                ] as Key,
              ]
            : []),
          fold,
        ])}
      </Box>
    );
  });

  // The message that asked: where the transcript scrolls to for its first question, and
  // drawn only up to the second once the rest have rows of their own.
  on("ui.render", { component: "AssistantMessage" }, async ($, e, next) => {
    if (!isInTranscript) return next(e);
    const { text } = e.props;
    let known = asked.get(e.requestId);
    if (known?.length !== text.length) {
      const form = e.props.isSummary ? null : parse(text);
      known = { length: text.length, form: form ? formId(form) : null };
      asked.set(e.requestId, known);
    }
    if (!known.form) return next(e);
    // Read so the row draws again when the form changes, even one it no longer holds.
    const c = await read($, current);
    if (c?.view.id === known.form) row = { form: known.form, requestId: e.requestId };
    const head = splitOf(await read($, splits), known.form)?.head;
    return head === undefined ? next(e) : next({ ...e, props: { ...e.props, text: head } });
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));

  // Drawn under the last question instead, by that question's row.
  on("ui.render", { component: "TurnDuration" }, async ($, e, next) => {
    const all = isInTranscript ? await read($, splits) : [];
    if (e.props.isExpanded || !all.some((split) => split.durationMs === e.props.durationMs))
      return next(e);
    const { Box } = $.ui.resolve(e);
    return <Box />;
  });

  on("ui.render", { component: "Placed" }, async ($, e, next) => {
    // With the option off the rows an earlier setting placed draw nothing, their message whole.
    const all = isInTranscript && e.props.plugin === "answer" ? await read($, splits) : [];
    const split = all.find((one) => one.rows.some((row) => row.id === e.props.id));
    const at = split?.rows.findIndex((row) => row.id === e.props.id) ?? -1;
    const row = split?.rows[at];
    if (!split || !row) return next(e);
    const { Box, Text, Markdown } = $.ui.resolve(e);
    const isLast = at === split.rows.length - 1;
    return (
      <Box flexDirection="column" rowGap={1} marginTop={1}>
        {/* The gutter a message's own text has. */}
        <Box paddingLeft={2}>
          <Markdown key="question" text={row.text} />
        </Box>
        {isLast && split.durationMs !== null ? (
          <Text dimColor>{`✻ Worked for ${lasted(split.durationMs)}`}</Text>
        ) : null}
      </Box>
    );
  });

  // The person's own moves of the ring over the form.
  on("ui.focus", async ($, e, next) => {
    const c =
      e.component === "AbovePrompt" && e.origin.kind === "person" ? await read($, current) : null;
    const item = c?.isOpen ? c.view.item : null;
    if (!c || !item || !e.element) return next(e);
    const isEntry = /^e\d+$/.test(e.element);
    // The click that picked an answer puts the ring on it just after its note took the ring.
    if (c.editing === NOTE && isEntry && (await $.clock.now()) - askedAt < CLICK_MS)
      return next({ ...e, element: keyOf(NOTE) });
    const moved = await next(e);
    if (moved.deny) return moved;
    // A write-in field left untouched is a row again; only a press opens it.
    if (c.editing === WRITE && e.element !== keyOf(WRITE) && typed === null)
      await edit($, (was) => ({ ...was, editing: null }));
    return moved;
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));
};
