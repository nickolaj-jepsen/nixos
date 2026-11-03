/** A person's step through the draft (`forms.apply` in agent-hub). */
export type Action =
  | { do: "pick"; entry: number }
  | { do: "write" | "note"; text: string }
  | { do: "go"; step: number }
  | { do: "back" | "forward" | "skip" | "review" };

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

/** What the form is typing into: the shown item's free-text answer, or a note. */
export type Editing = "text" | "note" | null;

/** The last turn's form, while it can still be answered. */
export type Current = { view: View; editing: Editing };

declare module "claude-code" {
  interface PluginState {
    answer: {
      current: Shaped<Current | null>;
    };
  }
}
