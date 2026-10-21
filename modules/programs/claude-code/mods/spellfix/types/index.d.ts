export type Miss = { word: string; start: number; end: number };

export type Picker = Miss & {
  before: string;
  after: string;
  suggestions: string[];
  ai: string | null;
  isAiDone: boolean;
  wantsAi: boolean;
};

export type Report = { original: string; fixed: string; changes: string[] };

declare module "claude-code" {
  interface PluginState {
    spellfix: { count: number; picker: Picker | null; report: Report | null; isBusy: boolean };
  }
}
