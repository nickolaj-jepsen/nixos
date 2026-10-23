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

// A pool alarm names its pool only while the provider sits beside it, so the two
// leave together once the parts that say nothing about the pool are gone.
const POOL_ALARMS: ReadonlySet<string> = new Set(["quota", "credit"]);

export type BranchMode = "full" | "glyph" | "none";

export type FooterInput = {
  /** The virtual selection's name, shown only while its router tracks a phase. */
  selection?: Part;
  /** The router's phase, `(plan)`; tight to the selection, and dropped with it. */
  phase?: Part;
  provider?: Part;
  /** Full model name, collapsing to `short`; it is the part that truncates. */
  model: Part;
  effort?: Part;
  statuses: Part[];
  /** Quota/credit, cache miss, context fallback: they outlive the steady meters. */
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
  let selection = true;
  let provider = true;
  let providerShort = false;
  let effort = true;
  let alarms = true;
  let keepPoolAlarms = true;
  let path = true;
  let shortModel = false;
  let modelText = input.model.text;
  const poolAlarm = input.alarms.some((part) => POOL_ALARMS.has(part.id));
  const dropProvider = () => {
    provider = false;
    keepPoolAlarms = false;
  };

  const compose = () => {
    const left = [
      selection ? input.selection : undefined,
      selection ? input.phase : undefined,
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
    // A tight part with nothing before it starts the line.
    if (left[0]?.tight) left[0] = { ...left[0], tight: false };
    const right = [
      ...(alarms ? input.alarms.filter((part) => keepPoolAlarms || !POOL_ALARMS.has(part.id)) : []),
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
    () => (selection = false),
    () => (statuses = false),
    () => (path = false),
    () => (speed = false),
    () => (cost = false),
    () => (branch = "glyph"),
    // A pool alarm needs its provider to mean anything, so with one on screen the
    // provider outlives the effort icon and the branch and leaves with the alarm.
    ...(poolAlarm ? [] : [dropProvider]),
    () => {
      shortModel = true;
      modelText = input.model.short ?? input.model.text;
    },
    () => (effort = false),
    () => (branch = "none"),
    ...(poolAlarm ? [dropProvider] : []),
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
  const git = layout.git
    ? " ".repeat(layout.gitGap) +
      (layout.git.styled ? layout.git.styled(theme) : theme.fg(layout.git.color, layout.git.text))
    : "";
  const line = pad + left.text + " ".repeat(fill) + right.text + git;
  // Still too wide after every step: cut the tail and keep only the left clicks.
  if (layout.used > inner) {
    return { line: truncateToWidth(line, width, "…"), regions: left.regions };
  }
  return { line: line + pad, regions: [...left.regions, ...right.regions] };
};
