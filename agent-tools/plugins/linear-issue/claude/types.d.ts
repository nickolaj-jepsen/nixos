/** The text of the card a Linear issue was drafted from, hidden until another card replaces it. */
export type Hidden = string | null;

/** One choice of a form Select: what Linear is sent, and what the person reads. */
export type Option = { value: string; label: string };

/** An open issue that already covers the seed, and the comment proposed for it. */
export type Duplicate = { issue: string; title: string; comment: string };

/** The draft pane's state; null while no draft is open. */
export type Form = {
  // Tells a late duplicate check whether its draft is still the one open.
  draftId: string;
  phase: "drafting" | "ready" | "filing" | "failed";
  error: string | null;
  // Appended to the description when filed: repository, branch and session.
  source: string;
  teams: Option[];
  statuses: Option[];
  labels: Option[];
  projects: Option[];
  team: string;
  title: string;
  // Bumped on Enter in the title field, which remounts it (see its render).
  titleRevision: number;
  description: string;
  priority: number;
  state: string;
  labelIds: string[];
  project: string;
  duplicate: Duplicate | null;
  isCheckingDuplicates: boolean;
};

/** What the last filed issue used, the fallback for the next draft. */
export type Last = { team: string; priority: number };

/** An issue filed this session, echoed above the prompt until dismissed. */
export type Filed = { key: string; title: string; url: string };

declare module "claude-code" {
  interface PluginState {
    "linear-issue": {
      hidden: Hidden;
      form: Form | null;
      filed: Filed[];
      // Whether the draft pane is shown; a hidden draft gets a chip above the prompt.
      isPaneOpen: boolean;
      // The key of the pane element holding the focus ring, for its border.
      focused: string | null;
      // Set by the chip's first Discard press; a second within a few seconds discards.
      isDiscardArmed: boolean;
    };
  }
}
