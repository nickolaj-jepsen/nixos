export type Miss = { word: string; start: number; end: number };

/** A typo Haiku found that hunspell didn't flag: a real word (`form` for `from`) or one hunspell skipped (`dense/consice`). */
export type Extra = Miss & { fix: string };

export type Picker = Miss & {
  before: string;
  after: string;
  suggestions: string[];
  isExtra: boolean;
  /** The fix most often picked for this word before, from the fix log. */
  guess: string | null;
  ai: string | null;
  isAiDone: boolean;
  wantsAi: boolean;
  wantsAll: boolean;
  /** Every fix the batch has for the draft, as `old→new`; `?` marks an extra. */
  summary: string[];
};

/** `original` is the draft and cursor fix-all started from. */
export type Report = {
  original: { text: string; cursor: number };
  fixed: string;
  changes: string[];
};

export type FixSource = "haiku" | "hunspell" | "history";

/** How often `to` was picked for `from` by each source, and how often Haiku's `to` was passed over. */
export type FixCount = { [K in FixSource | "rejected"]?: number } & { last: string };

/** The fix log's file: misspelling → replacement → counts. */
export type FixLog = Record<string, Record<string, FixCount>>;

declare module "claude-code" {
  interface PluginState {
    spellfix: {
      count: number;
      hasDraft: boolean;
      picker: Picker | null;
      report: Report | null;
      added: string[];
      isBusy: boolean;
    };
  }
}
