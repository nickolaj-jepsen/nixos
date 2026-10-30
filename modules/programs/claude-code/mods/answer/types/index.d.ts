export type Kind = "round" | "picks";

export type Option = {
  /** What the reply says for it: the round's letter, or a pick's route. */
  key: string;
  text: string;
  /** The lines that continued it, drawn under it. */
  detail: string;
};

export type Item = {
  /** As printed ("Q3", "2"); the reply addresses the item by it. */
  label: string;
  title: string;
  /** Markdown: what the item said besides its title, options and recommendation. */
  body: string;
  options: Option[];
  recommended?: string;
  /** The option the recommendation names. */
  recommendedOption?: number;
};

export type Form = { kind: Kind; items: Item[] };

export type Answer =
  | { kind: "accept" }
  | { kind: "option"; index: number }
  | { kind: "text"; text: string };

export type Draft = {
  /** One per item; null is skipped. */
  answers: (Answer | null)[];
  /** One per item; "" is none. */
  notes: string[];
  /** Said last, about the whole round. */
  note: string;
  /** The item shown, or items.length for the review. */
  step: number;
};

export type Route = "build" | "/grill-me" | "/brainstorm";

/** What the form is typing into: the shown item's free-text answer, or a note. */
export type Editing = "text" | "note" | null;

/** The last turn's form, while it can still be answered. */
export type Current = { form: Form; draft: Draft; editing: Editing };

declare module "claude-code" {
  interface PluginState {
    answer: {
      current: Shaped<Current | null>;
    };
  }
}
