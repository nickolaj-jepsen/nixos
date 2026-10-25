export type MenuKind = "git" | "folder";

export type FolderApp = "code" | "smerge" | "files" | "ghostty";

/** What a row does when pressed; plain data, so the menu survives a reload. */
export type Action =
  | { kind: "url"; url: string }
  | { kind: "copy"; text: string; what: string }
  | { kind: "launch"; argv: string[] };

export type Row = {
  id: string;
  label: string;
  /** A short note beside the label: a host, a state, a destination. */
  description?: string;
  /** Why the row cannot run; it keeps its place and says this when pressed. */
  unavailable?: string;
  action?: Action;
};

export type Menu = {
  kind: MenuKind;
  title: string;
  /** Beside the title, e.g. the repository the rows act on. */
  context?: string;
  /** Null while git and gh are still answering. */
  rows: Row[] | null;
  /** The row the focus starts on. */
  preferred?: string;
  /** Why the menu has no rows, e.g. not a repository. */
  error?: string;
};

declare module "claude-code" {
  interface PluginState {
    "git-menu": {
      menu: Menu | null;
    };
  }
}
