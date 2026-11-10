/** A person's step through the draft (`forms.apply` in agent-hub). */
export type Action =
  | { do: "pick" | "toggle"; entry: number }
  | { do: "write" | "note"; text: string }
  | { do: "go"; step: number }
  | { do: "accept" | "next" | "back" | "forward" | "skip" | "review" };

export type Entry = {
  kind: "option" | "accept" | "write";
  text: string;
  /** The lines that continued it, drawn under it. */
  detail: string;
  isRecommended: boolean;
  isChosen: boolean;
};

export type Item = {
  /** As printed ("Q3", "2"). */
  label: string;
  title: string;
  /** Markdown: what the item said besides its title, options and recommendation. */
  body: string;
  entries: Entry[];
  /** The entry the cursor starts on. */
  start: number;
  /** What it recommends among its options and why, "" with none. */
  recommended: string;
  /** Whether several of its options can be one answer, and whether its answer is several. */
  canSeveral: boolean;
  isSeveral: boolean;
  /** Whether it recommends something a yes can take. */
  canAccept: boolean;
  note: string;
  /** The write-in answer, "" for none. */
  written: string;
};

/** What `agent-hub answer` prints: all there is to draw (`FORM_VIEW` in its protocol). */
export type View = {
  id: string;
  kind: "round" | "picks";
  title: string;
  count: number;
  answered: number;
  /** The item shown, or `count` for the review. */
  step: number;
  isReview: boolean;
  item: Item | null;
  review: { label: string; shown: string; isAnswered: boolean; note: string }[];
  /** Said last, about the whole round. */
  note: string;
  reply: string;
  pending: boolean;
};

/** A reply another surface left for this session's prompt. */
export type Delivery = { text: string; submit: boolean };

/** The field being typed in: the shown item's write-in, or a note. */
export type Editing = "write" | "note" | null;

/** The last turn's form, while it can still be answered. */
export type Current = {
  view: View;
  editing: Editing;
  /** Whether picks toggle on the shown item; null follows its answer. */
  several: boolean | null;
  /** Drawn as the form, not its one row. */
  isOpen: boolean;
  /** The prompt's text, set aside while the form is open; null with none. */
  stash: string | null;
  /** The reply the last fill put in the prompt, so the next one takes its place. */
  filled: string | null;
};

declare module "claude-code" {
  interface PluginState {
    answer: {
      current: Shaped<Current | null>;
    };
  }
}
