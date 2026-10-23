import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { paintParts, partsWidth, type Part, type Region } from "./layout.ts";

export const PAD = 2;
// Between the left zone and the meters, and between the meters and git.
const ZONE_GAP = 2;
const GIT_GAP = 3;
// The model keeps at least this many columns before alarms give way.
const MODEL_MIN = 8;

export type BranchMode = "full" | "glyph" | "none";

export type FooterInput = {
  provider?: Part;
  /** The full model alias; it is the part that truncates. */
  model: Part;
  effort?: Part;
  statuses: Part[];
  /** Quota/credit, cache miss, context fallback: they outlive the steady meters. */
  alarms: Part[];
  cost?: Part;
  speed?: Part;
  git: (mode: BranchMode) => Part | null;
};

/**
 * Words on the left, meters right-aligned before git. When the line does not
 * fit, parts give way in a fixed order: statuses, speed, cost, branch name,
 * provider, effort, git, model width (down to MODEL_MIN), alarms.
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
  let effort = true;
  let alarms = true;
  let modelText = input.model.text;

  const compose = () => {
    const left = [
      provider ? input.provider : undefined,
      { ...input.model, text: modelText },
      effort ? input.effort : undefined,
      ...(statuses ? input.statuses : []),
    ].filter((part): part is Part => part !== undefined);
    // A tight part with nothing before it starts the line.
    if (left[0]?.tight) left[0] = { ...left[0], tight: false };
    const right = [
      ...(alarms ? input.alarms : []),
      cost ? input.cost : undefined,
      speed ? input.speed : undefined,
    ].filter((part): part is Part => part !== undefined);
    const git = input.git(branch);
    const leftWidth = partsWidth(left);
    const rightWidth = partsWidth(right);
    const gitWidth = git ? visibleWidth(git.text) : 0;
    const used =
      leftWidth + (rightWidth > 0 ? ZONE_GAP + rightWidth : 0) + (git ? GIT_GAP + gitWidth : 0);
    return { left, right, git, leftWidth, rightWidth, gitWidth, used };
  };

  let layout = compose();
  const steps: Array<() => void> = [
    () => (statuses = false),
    () => (speed = false),
    () => (cost = false),
    () => (branch = "glyph"),
    () => (provider = false),
    () => (effort = false),
    () => (branch = "none"),
    () => {
      const room = inner - (layout.used - visibleWidth(modelText));
      modelText = truncateToWidth(input.model.text, Math.max(MODEL_MIN, room), "…");
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
  const gitBlock = layout.git ? GIT_GAP + layout.gitWidth : 0;
  const fill = Math.max(0, inner - layout.leftWidth - layout.rightWidth - gitBlock);
  const right = paintParts(layout.right, theme, PAD + layout.leftWidth + fill, hovered);
  const git = layout.git
    ? " ".repeat(GIT_GAP) +
      (layout.git.styled ? layout.git.styled(theme) : theme.fg(layout.git.color, layout.git.text))
    : "";
  const line = pad + left.text + " ".repeat(fill) + right.text + git;
  // Still too wide after every step: cut the tail and keep only the left clicks.
  if (layout.used > inner) {
    return { line: truncateToWidth(line, width, "…"), regions: left.regions };
  }
  return { line: line + pad, regions: [...left.regions, ...right.regions] };
};
