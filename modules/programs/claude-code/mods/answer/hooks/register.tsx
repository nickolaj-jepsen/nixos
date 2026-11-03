import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { Action, Current, Delivery, Entry, View } from "../types";

const PANE = "answer";
// Borrowed: mods can't define keybinding actions, and the engine handles this
// one only while the diff panel is open. A key bound to it in keybindings.json
// presses the band's button from the prompt.
const ACTION = "app:cycleDiffBase";
const CHORD = "alt+a";
// The dock is held to 45% of the terminal; ask for all of it.
const COLUMNS = 120;
const FIELD = "field";
// How soon something another surface did to the form shows here.
const POLL_MS = 1000;

// Change the tag when Current changes shape: a reload keeps what the old code stored.
const current = atom({ plugin: "answer", key: "current" } as const, null, { shape: "current-4" });

/** Origins that are the person speaking; a task's notification or a peer's message isn't. */
const PERSON = new Set<string>(["composer", "bridge", "sdk", "slack-ping"]);

/** Runs `agent-hub answer`, which works with the hub down; the draft lives in its file. */
async function hub($: EngineInterface, args: string[], stdin?: string): Promise<string> {
  const session = await $.session.id();
  const run = await $.process.run(["agent-hub", "answer", ...args, "--session", session], {
    ...(stdin === undefined ? {} : { stdin }),
    timeoutMs: 5000,
  });
  if (run.exitCode !== 0) throw new Error(run.stderr.trim() || `exit ${run.exitCode}`);
  return run.stdout;
}

const hubView = async ($: EngineInterface, args: string[], stdin?: string) =>
  JSON.parse(await hub($, args, stdin)) as View | null;

const complain = ($: EngineInterface, error: unknown) =>
  $.ui.log(`answer: ${String(error)}`, { to: "debug" });

/** Shows the view; a field stays open only while it still types into what is shown. */
const show = ($: EngineInterface, view: View | null) =>
  update($, current, (c) =>
    view
      ? {
          view,
          editing: c && c.view.id === view.id && c.view.step === view.step ? c.editing : null,
        }
      : null,
  );

const edit = ($: EngineInterface, fn: (c: Current) => Current) =>
  update($, current, (c) => (c ? fn(c) : c));

const isOpen = async ($: EngineInterface) => (await $.ui.panes()).some((p) => p.id === PANE);

/** Moves the focus ring; cosmetic, so a ring that can't move leaves the keys working. */
const focus = ($: EngineInterface, key: string) =>
  $.ui.focus({ requestId: PANE, key }).catch(() => undefined);

/** One step of the draft, and what it now shows; null when it couldn't be taken, with a toast. */
async function step($: EngineInterface, action: Action): Promise<View | null> {
  const c = await read($, current);
  if (!c) return null;
  try {
    const view = await hubView($, ["step", "--form", c.view.id, JSON.stringify(action)]);
    await update($, current, () => (view ? { view, editing: null } : null));
    return view;
  } catch (error) {
    $.ui.toast(`The answer form can't step: ${String(error)}`);
    return null;
  }
}

/** Shows another item, its ring on the answer or the recommendation. */
async function move($: EngineInterface, action: Action) {
  const view = await step($, action);
  if (view) await focus($, view.item ? `e${view.item.start}` : "fill");
}

/** Edits a field and hands it the ring: the write-in, or a note after an answer. */
async function startEditing($: EngineInterface, editing: "text" | "note") {
  await edit($, (c) => ({ ...c, editing }));
  await focus($, FIELD);
}

/** A picked entry: an answer, then its note; a write-in opens its field instead. */
async function choose($: EngineInterface, entry: Entry, index: number) {
  if (entry.kind === "write") return startEditing($, "text");
  if (await step($, { do: "pick", entry: index })) await startEditing($, "note");
}

/**
 * Opens the form. Called before any other await of a press: an open that comes
 * after the press has returned counts as the plugin's own, and waits undrawn
 * below 144 columns.
 */
async function open($: EngineInterface, view: View) {
  const opened = await $.ui.open({
    id: PANE,
    title: view.title,
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
  await open($, c.view);
}

/** The reply above what the person had typed, never over it. */
const placeReply = (draft: string, text: string) => (draft.trim() ? `${text}\n\n${draft}` : text);

/** Writes the reply into the prompt, above any draft, for the person to send. */
async function fill($: EngineInterface, text: string): Promise<boolean> {
  const box = await $.prompt.read();
  const { isFilled } = await $.prompt.fill({ text: placeReply(box.text, text), mode: "replace" });
  if (isFilled && (await isOpen($))) await $.ui.close({ id: PANE });
  return isFilled;
}

/** A reply left at another surface: into the prompt, or sent as you sending it. */
async function take($: EngineInterface, delivery: Delivery) {
  if (delivery.submit) {
    if (await isOpen($)) await $.ui.close({ id: PANE });
    await $.prompt.submit({ text: delivery.text });
  } else if (!(await fill($, delivery.text))) {
    $.ui.toast("The answer couldn't go in the prompt: a dialog is open.");
  }
}

/** Follows the form's file, so what another surface does shows here and its replies arrive. */
function watch($: EngineInterface) {
  let watched = { session: "", path: "", mtime: 0 };
  let isBusy = false;
  return $.clock.every(POLL_MS, async () => {
    if (isBusy) return;
    isBusy = true;
    try {
      const session = await $.session.id();
      if (session !== watched.session) {
        const path = (await hub($, ["path"])).trim();
        watched = { session, path, mtime: 0 };
      }
      const mtime = await $.fs.stat(watched.path).then(
        (s) => s.mtimeMs,
        () => 0,
      );
      if (mtime === watched.mtime) return;
      watched.mtime = mtime;
      const { view, delivery } = JSON.parse(await hub($, ["sync"])) as {
        view: View | null;
        delivery: Delivery | null;
      };
      await show($, view);
      if (delivery) await take($, delivery);
    } catch (error) {
      complain($, error);
    } finally {
      isBusy = false;
    }
  });
}

/**
 * The item a person's scroll of the pane moves to, or null to let it scroll.
 *
 * Home and End (and ←/→, bound to them) scroll by the whole tree with no pointer;
 * those move back and forward. Inline, a page key on a tree that fits reads the same.
 */
function arrowAction(scroll: {
  by: number;
  contentRows: number;
  hasPointer: boolean;
}): Action | null {
  if (scroll.hasPointer || scroll.by === 0 || Math.abs(scroll.by) !== scroll.contentRows)
    return null;
  return { do: scroll.by > 0 ? "forward" : "back" };
}

export const register: Register = (on) => {
  let ticking: { cancel: () => void } | undefined;

  on("session.start", async ($, e, next) => {
    await $.command
      .register({
        name: "answer",
        description: "Answer the questions or pick list the last turn ended on, from a form",
        immediate: true,
      })
      .catch((error) => complain($, `/answer not registered: ${String(error)}`));
    ticking?.cancel();
    ticking = watch($);
    return next(e);
  });

  // Only a new round replaces the form; the person's send is what drops it. A turn a
  // background task woke ends on that task's news while the round still waits.
  on("turn.complete", async ($, e, next) => {
    if (e.agentId === undefined && e.reason === "answer")
      await hubView($, ["offer"], e.answer).then(
        (view) => show($, view),
        (error) => complain($, error),
      );
    return next(e);
  });

  // The person's own message answers the round, or moves past it.
  on("prompt.submit", async ($, e, next) => {
    if (PERSON.has(e.origin.kind) && (await read($, current))) {
      await update($, current, () => null);
      if (await isOpen($)) await $.ui.close({ id: PANE });
      await hub($, ["drop"]).catch((error) => complain($, error));
    }
    return next(e);
  }).catch((_$, e, next) => (next.called ? undefined : next(e)));

  on("ui.scroll", { component: "Pane", requestId: PANE }, async ($, e, next) => {
    const c = e.origin.kind === "person" ? await read($, current) : null;
    const scroll = { by: e.by, contentRows: e.contentRows, hasPointer: e.pointer !== undefined };
    const action = c ? arrowAction(scroll) : null;
    if (!action) return next(e);
    await move($, action);
    return {};
  });

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
    const { answered, title } = c.view;
    // Kept mounted while there is a form: the key bound to ACTION reaches only a mounted Button.
    return (
      <Box flexDirection="column">
        {below}
        <Button key="answer" plain action={ACTION} onPress={() => void open($, c.view)}>
          {title}
          <Text
            dimColor
          >{`${answered ? ` · ${answered} answered` : ""} · ${CHORD} or /answer`}</Text>
        </Button>
      </Box>
    );
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    const els = $.ui.resolve(e);
    const { Box, Text, Button, Markdown } = els;
    const c = await read($, current);
    if (!c) return <Text dimColor>Nothing to answer.</Text>;
    const { view, editing } = c;
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
    const back = () => move($, { do: "back" });

    if (!view.item) {
      const saveNote = async (t: string) => {
        if (await step($, { do: "note", text: t })) await focus($, "fill");
      };
      return (
        <Box flexDirection="column" rowGap={1}>
          <Text weight="semibold">Review</Text>
          <Box flexDirection="column">
            {view.review.map((row, i) => (
              <Button
                key={`item${i}`}
                plain
                hotkey={i < 9 ? String(i + 1) : undefined}
                onPress={() => void move($, { do: "go", step: i })}
              >
                {`${row.label}  `}
                <Text dimColor={!row.isAnswered}>{row.shown}</Text>
                {row.note ? <Text dimColor>{` — ${row.note}`}</Text> : null}
              </Button>
            ))}
          </Box>
          {editing === "note" ? (
            field("A note on the whole round, Enter to keep", view.note, (t) => void saveNote(t))
          ) : view.note ? (
            <Text>{`Note: ${view.note}`}</Text>
          ) : null}
          <Box flexDirection="column">
            <Text dimColor>The reply:</Text>
            <Text>{view.reply || "(nothing answered yet)"}</Text>
          </Box>
          <Button
            key="fill"
            variant="primary"
            autoFocus={editing ? undefined : true}
            label="fill the prompt"
            onPress={() => {
              if (view.reply) void fill($, view.reply);
              else $.ui.toast("Nothing answered yet.");
            }}
          />
          {nav([
            ["n", "note", () => startEditing($, "note")],
            ["b", "back", back],
          ])}
          <Text dimColor>1-9 revisits · ← back · Esc closes, answers kept</Text>
        </Box>
      );
    }

    const { item } = view;
    return (
      <Box flexDirection="column" rowGap={1}>
        <Text dimColor>{`${item.label} · ${view.step + 1} of ${view.count}`}</Text>
        <Text weight="semibold">{item.title}</Text>
        {item.body ? <Markdown key="body" text={item.body} /> : null}
        <Box flexDirection="column">
          {item.entries.map((entry, k) => (
            <Box key={`row${k}`} flexDirection="column">
              <Button
                key={`e${k}`}
                plain
                hotkey={k < 9 ? String(k + 1) : undefined}
                autoFocus={!editing && k === item.start ? true : undefined}
                onPress={() => void choose($, entry, k)}
              >
                {entry.text}
                {entry.isRecommended ? <Text dimColor> (recommended)</Text> : null}
                {entry.isChosen ? <Text color="success"> ✓</Text> : null}
              </Button>
              {entry.detail ? (
                <Text dimColor>{`   ${entry.detail.replace(/\n/g, "\n   ")}`}</Text>
              ) : null}
            </Box>
          ))}
        </Box>
        {item.written && editing !== "text" ? <Text>{`Your answer: ${item.written}`}</Text> : null}
        {editing === "text"
          ? field(
              "Your answer, Enter to save",
              item.written,
              (t) => void move($, { do: "write", text: t }),
            )
          : null}
        {editing === "note" ? (
          field(
            "A note, or Enter to go on",
            item.note,
            (t) => void move($, { do: "note", text: t }),
          )
        ) : item.note ? (
          <Text dimColor>{`Note: ${item.note}`}</Text>
        ) : null}
        {nav([
          ["b", "back", back],
          ["f", "forward", () => move($, { do: "forward" })],
          ["s", "skip", () => move($, { do: "skip" })],
          ["r", "review", () => move($, { do: "review" })],
        ])}
        <Text dimColor>
          1-9 or Enter answers · ←→ questions · ↑↓ or Tab moves · Esc closes, answers kept
        </Text>
      </Box>
    );
  });
};
