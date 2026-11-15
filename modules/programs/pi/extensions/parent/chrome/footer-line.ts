import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { paintParts, partsWidth, type Part, type Region } from "./layout.ts";

const PAD = 2;
// Between the left zone and the right one.
const ZONE_GAP = 2;
// Git follows the path as one phrase (`~/nixos  branch`); the branch glyph is the separator.
const PATH_GIT_GAP = 1;
const GIT_GAP = 3;
// The model keeps at least this many columns before alarms give way.
const MODEL_MIN = 8;

export type BranchMode = "full" | "glyph" | "none";

export type FooterInput = {
  provider?: Part;
  /** Full model name, collapsing to `short`; it is the part that truncates. */
  model: Part;
  effort?: Part;
  statuses: Part[];
  /** Cache miss, context fallback: they outlive the steady meters. */
  alarms: Part[];
  /** Working directory; only shown here because the borders carry the label and meters. */
  path?: Part;
  cost?: Part;
  speed?: Part;
  git: (mode: BranchMode) => Part | null;
};

/**
 * Words on the left, meters right-aligned before git. When the line does not
 * fit, parts give way in the order of `steps`.
 */
export const layoutFooter = (
  width: number,
  theme: Theme,
  input: FooterInput,
  hovered?: string,
): { line: string; regions: Region[] } => {
  if (width <= PAD * 2) return { line: "", regions: [] };
  const inner = width - PAD * 2;

  let statuses = true;
  let speed = true;
  let cost = true;
  let branch: BranchMode = "full";
  let provider = true;
  let providerShort = false;
  let effort = true;
  let alarms = true;
  let path = true;
  let shortModel = false;
  let modelText = input.model.text;

  const compose = () => {
    const left = [
      provider && input.provider
        ? {
            ...input.provider,
            text: providerShort
              ? (input.provider.short ?? input.provider.text)
              : input.provider.text,
          }
        : undefined,
      {
        ...input.model,
        text: modelText,
        // The painted form is bound to the text it was built for; a swapped or
        // truncated text has to fall back to a plain colour.
        styled: modelText === input.model.text ? input.model.styled : undefined,
      },
      effort ? input.effort : undefined,
      ...(statuses ? input.statuses : []),
    ].filter((part): part is Part => part !== undefined);
    const right = [
      ...(alarms ? input.alarms : []),
      cost ? input.cost : undefined,
      speed ? input.speed : undefined,
      path ? input.path : undefined,
    ].filter((part): part is Part => part !== undefined);
    const git = input.git(branch);
    const leftWidth = partsWidth(left);
    const rightWidth = partsWidth(right);
    const gitWidth = git ? visibleWidth(git.text) : 0;
    const gitGap = path && input.path ? PATH_GIT_GAP : GIT_GAP;
    const used =
      leftWidth + (rightWidth > 0 ? ZONE_GAP + rightWidth : 0) + (git ? gitGap + gitWidth : 0);
    return { left, right, git, leftWidth, rightWidth, gitWidth, gitGap, used };
  };

  let layout = compose();
  const steps: Array<() => void> = [
    () => (providerShort = true),
    () => (statuses = false),
    () => (speed = false),
    () => (cost = false),
    // Where the session is says more than what it has cost, so the path survives
    // both meters and only goes when the model itself needs the room.
    () => (path = false),
    () => (branch = "glyph"),
    () => (provider = false),
    () => {
      shortModel = true;
      modelText = input.model.short ?? input.model.text;
    },
    () => (effort = false),
    () => (branch = "none"),
    () => {
      const room = inner - (layout.used - visibleWidth(modelText));
      modelText = truncateToWidth(
        shortModel ? (input.model.short ?? input.model.text) : input.model.text,
        Math.max(MODEL_MIN, room),
        "…",
      );
    },
    () => (alarms = false),
  ];
  for (const step of steps) {
    if (layout.used <= inner) break;
    step();
    layout = compose();
  }

  const pad = " ".repeat(PAD);
  const left = paintParts(layout.left, theme, PAD, hovered);
  const gitBlock = layout.git ? layout.gitGap + layout.gitWidth : 0;
  const fill = Math.max(0, inner - layout.leftWidth - layout.rightWidth - gitBlock);
  const right = paintParts(layout.right, theme, PAD + layout.leftWidth + fill, hovered);
  // Git is painted outside the part list, so it gets its region and its hover
  // here: the branch, its status and the PR glyph are one target.
  const gitStart =
    PAD + layout.leftWidth + fill + layout.rightWidth + (layout.git ? layout.gitGap : 0);
  const lit = layout.git?.action !== undefined && layout.git.id === hovered;
  const git = layout.git
    ? " ".repeat(layout.gitGap) +
      (layout.git.styled
        ? lit
          ? theme.bold(layout.git.styled(theme))
          : layout.git.styled(theme)
        : theme.fg(
            lit ? "text" : layout.git.color,
            layout.git.bold ? theme.bold(layout.git.text) : layout.git.text,
          ))
    : "";
  const line = pad + left.text + " ".repeat(fill) + right.text + git;
  // Still too wide after every step: cut the tail and keep only the left clicks.
  if (layout.used > inner) {
    return { line: truncateToWidth(line, width, "…"), regions: left.regions };
  }
  const gitRegion = layout.git?.action
    ? [
        {
          x0: gitStart,
          x1: gitStart + layout.gitWidth,
          id: layout.git.id,
          action: layout.git.action,
        },
      ]
    : [];
  return { line: line + pad, regions: [...left.regions, ...right.regions, ...gitRegion] };
};
