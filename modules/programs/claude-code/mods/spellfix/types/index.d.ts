export type Miss = { word: string; start: number; end: number };

/** A typo Haiku found that hunspell didn't flag: a real word (`form` for `from`) or one hunspell skipped (`dense/consice`). */
export type Extra = Miss & { fix: string };

export type Picker = Miss & {
  before: string;
  after: string;
  suggestions: string[];
  isExtra: boolean;
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
