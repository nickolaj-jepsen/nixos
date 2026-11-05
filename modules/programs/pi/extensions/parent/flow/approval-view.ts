/**
 * The approval page's content and its edits (D13): one list of blocks that the
 * overlay draws and `APPROVAL.md` is written from, the page state the owner
 * changes, and the pure rewrites those changes land as.
 *
 * Nothing here touches pi or the filesystem: the page's text, the tier rewrite
 * and the Amendments entry are unit-tested without a terminal.
 */
import {
  budgetCaps,
  DEFAULT_SETTINGS,
  type Flow,
  isModelRef,
  type JudgeHandoffVerdict,
  type Level,
  type Mode,
  MODES,
  type ParsedHandoff,
  type ResolvedSettings,
  resolveSettings,
  ROLE_KEYS,
  SESSION_KEYS,
  SETTING_KEYS,
  type SettingKey,
  type SettingReport,
  type Tier,
} from "./contracts.ts";

/** One editable target and level; `target` is a model or role by key. */
export type PageSetting = { target: string; deep?: string; thinking?: Level };

/** What the owner may change on the page; approving applies all of it. */
export type PageState = {
  mode: Mode;
  settings: Record<SettingKey, PageSetting>;
  /** Item ID → the tier the item will be built at. */
  tiers: Record<string, Tier>;
  /** Question ID → the answer the owner typed. */
  answers: Record<string, string>;
};

/** One focusable line: the rows the owner edits and the actions that end the page. */
export type ApprovalRow =
  | { kind: "mode" }
  | { kind: "setting"; key: SettingKey }
  | { kind: "settingDeep"; key: "items" }
  | { kind: "settingThinking"; key: SettingKey }
  | { kind: "tier"; id: string }
  | { kind: "question"; id: string }
  | { kind: "approve" }
  | { kind: "back" }
  | { kind: "cancel" };

/** A line of the page: prose, or a row the owner can act on. */
export type ApprovalBlock =
  | { kind: "title" | "heading" | "text" | "bullet"; text: string }
  | { kind: "row"; row: ApprovalRow; label: string; value: string };

/** D14's three modes, as the page explains the chosen one; `flow-run` holds the rules. */
const MODE_MEANING: Record<Mode, string> = {
  gated: "stops at every gate and on every deviation",
  deviation: "self-checks ordinary gates and stops only on a deviation",
  straight: "logs deviations and continues to the final report",
};

/** What no mode changes, said once beside the modes. */
const EVERY_MODE =
  "A mode governs gates and deviations; the plan's ## Stops and flow-run's safety stops apply in every mode.";

/** A key whose default sets no thinking level is one whose role locks it (D5's `gateReview`). */
const thinkingLocked = (key: SettingKey): boolean => DEFAULT_SETTINGS[key].thinking === undefined;

/**
 * The page as it opens: the settings the flow resolved to, with the judge's
 * handoff verdict laid over them — the mode and the run step it suggests, and
 * any item tier it would move. Nothing of the verdict is in `FLOW.json` yet;
 * only what the owner approves is written.
 */
export const initialPage = (
  flow: Flow,
  handoff: ParsedHandoff,
  verdict: JudgeHandoffVerdict,
  settings: ResolvedSettings,
): PageState => ({
  mode: flow.mode ?? verdict.mode,
  settings: Object.fromEntries(
    SETTING_KEYS.map((key) => [
      key,
      {
        target: settings[key].model ?? settings[key].role ?? "",
        ...(settings[key].deep === undefined ? {} : { deep: settings[key].deep }),
        ...(settings[key].thinking === undefined ? {} : { thinking: settings[key].thinking }),
      },
    ]),
  ) as Record<SettingKey, PageSetting>,
  tiers: Object.fromEntries(
    handoff.items.map((item) => [item.id, verdict.tiers[item.id] ?? item.tier]),
  ),
  answers: {},
});

/**
 * The settings fields the owner changed on the page, in `FLOW.json.settings`'
 * shape: a session key's target is a model, a role key's target a role unless
 * it reads as `provider/model`. A field left as the page opened is not here, so
 * a default or a suggestion the owner never touched is not frozen as theirs.
 */
export const pageEdits = (
  opened: PageState,
  page: PageState,
): Partial<Record<SettingKey, Record<string, string>>> => {
  const edits: Partial<Record<SettingKey, Record<string, string>>> = {};
  for (const key of SETTING_KEYS) {
    const before = opened.settings[key];
    const after = page.settings[key];
    const edit: Record<string, string> = {};
    if (after.target !== before.target) {
      const asModel = (SESSION_KEYS as readonly string[]).includes(key) || isModelRef(after.target);
      edit[asModel ? "model" : "role"] = after.target;
    }
    if (after.deep !== undefined && after.deep !== before.deep) edit.deep = after.deep;
    if (after.thinking !== undefined && after.thinking !== before.thinking)
      edit.thinking = after.thinking;
    if (Object.keys(edit).length > 0) edits[key] = edit;
  }
  return edits;
};

/**
 * The flow after the page's edits (D13): the page's mode, and only the settings
 * fields the owner changed, laid over what the flow already holds. `reports`
 * names every edited value `resolveSettings` would refuse; a page with any
 * must not be approved, since the refused value would silently fall back.
 */
export const applyPage = (
  flow: Flow,
  opened: PageState,
  page: PageState,
): { flow: Flow; reports: SettingReport[] } => {
  const edits = pageEdits(opened, page);
  const reports = resolveSettings(DEFAULT_SETTINGS, undefined, edits).reports;
  const settings: Record<string, unknown> = { ...flow.settings };
  for (const [key, edit] of Object.entries(edits)) {
    const held = settings[key];
    const below: Record<string, unknown> =
      typeof held === "object" && held !== null && !Array.isArray(held) ? { ...held } : {};
    // A step has one target; leaving the other field would let it win (C2).
    if ("model" in edit) delete below.role;
    if ("role" in edit) delete below.model;
    settings[key] = { ...below, ...edit };
  }
  return { flow: { ...flow, mode: page.mode, settings }, reports };
};

/** One item's `Tier:` line and the tier it should read after the page. */
export type TierEdit = { line: number; tier: Tier };

/**
 * The tiers the owner moved on the page (D8): compared with what the page
 * opened on, not with the file, so a suggestion the judge made and the owner
 * left alone is not written to `HANDOFF.md` as the owner's.
 */
export const tierEdits = (handoff: ParsedHandoff, opened: PageState, page: PageState): TierEdit[] =>
  handoff.items
    .filter((item) => item.tierLine > 0 && page.tiers[item.id] !== undefined)
    .filter((item) => page.tiers[item.id] !== opened.tiers[item.id])
    .map((item) => ({ line: item.tierLine, tier: page.tiers[item.id] }));

/**
 * `HANDOFF.md` with those `Tier:` lines rewritten, and nothing else touched.
 * Throws on a line that is no longer a `- Tier: flash|deep` bullet, which means
 * the file changed under the page and approving it would build something else.
 */
export const rewriteTiers = (text: string, edits: readonly TierEdit[]): string => {
  if (edits.length === 0) return text;
  const lines = text.split(/\r?\n/);
  for (const edit of edits) {
    const at = edit.line - 1;
    const line = lines[at];
    if (line === undefined) throw new Error(`HANDOFF.md has no line ${edit.line} to rewrite`);
    const match = /^(\s*-\s*Tier:\s*)(\S+)(\s*)$/.exec(line);
    if (!match || (match[2] !== "flash" && match[2] !== "deep"))
      throw new Error(`HANDOFF.md line ${edit.line} is not a "- Tier: flash|deep" bullet`);
    lines[at] = `${match[1]}${edit.tier}${match[3]}`;
  }
  return lines.join("\n");
};

/** The Amendments entry for one answer: dated, and sourced as the page (D13). */
export const amendmentFor = (date: string, id: string, answer: string): string =>
  `- ${date}, owner, approval page: ${id} answered: ${answer}`;

/** Today as `YYYY-MM-DD`, in the owner's own timezone rather than UTC's. */
export const today = (at: Date = new Date()): string => {
  const month = `${at.getMonth() + 1}`.padStart(2, "0");
  const day = `${at.getDate()}`.padStart(2, "0");
  return `${at.getFullYear()}-${month}-${day}`;
};

/** The page's answers as Amendments entries, in the order the questions are written. */
export const amendmentEntries = (handoff: ParsedHandoff, page: PageState, date: string): string[] =>
  handoff.openQuestions
    .filter((question) => (page.answers[question.id] ?? "").trim() !== "")
    .map((question) => amendmentFor(date, question.id, page.answers[question.id].trim()));

/**
 * `HANDOFF.md` with those entries appended under `## Amendments`, dated, with
 * nothing already written rewritten (C6). Creates the section when the plan has
 * none, and keeps one blank line between it and whatever follows.
 */
export const appendAmendments = (text: string, entries: readonly string[]): string => {
  if (entries.length === 0) return text;
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((line) => /^##\s+Amendments\s*$/.test(line));
  if (at < 0) return `${text.replace(/\s*$/, "")}\n\n## Amendments\n\n${entries.join("\n")}\n`;
  let end = lines.length;
  for (let index = at + 1; index < lines.length; index += 1) {
    if (/^##\s/.test(lines[index])) {
      end = index;
      break;
    }
  }
  let insert = end;
  while (insert > at + 1 && lines[insert - 1].trim() === "") insert -= 1;
  const after = lines.slice(insert);
  const block = ["", ...entries];
  if (after.length > 0) block.push("");
  return [...lines.slice(0, insert), ...block, ...after].join("\n");
};

/** The acceptance as the page shows it, with C6's unverified flag spelled out. */
const acceptanceText = (acceptance: string, unverified: boolean): string =>
  unverified
    ? `Acceptance (unverified) — nobody has run it yet: ${acceptance.replace(/\(unverified\)\s*$/, "").trim()}`
    : `Acceptance: ${acceptance}`;

/**
 * The page's content (D13), in reading order: what the plan is for, what it
 * leaves out, the run's settings and mode, the items with their blockers, the
 * stops and the budget, the acceptance commands, and the open questions the
 * owner answers here.
 */
export const approvalBlocks = (
  flow: Flow,
  handoff: ParsedHandoff,
  page: PageState,
  settings: ResolvedSettings,
): ApprovalBlock[] => {
  const blocks: ApprovalBlock[] = [
    { kind: "title", text: `Approval: ${flow.slug}` },
    {
      kind: "text",
      text: `${flow.planDir} · base ${flow.base} · branch ${flow.branch}`,
    },
    { kind: "heading", text: "Mission" },
    { kind: "text", text: handoff.mission },
    { kind: "heading", text: "Smallest version" },
    { kind: "text", text: handoff.smallestVersion },
    { kind: "heading", text: "Not building" },
    ...handoff.notBuilding.map((text) => ({ kind: "bullet" as const, text })),
    { kind: "heading", text: "The run" },
    {
      kind: "row",
      row: { kind: "mode" },
      label: "Mode",
      value: `${page.mode} — ${MODE_MEANING[page.mode]}`,
    },
    {
      kind: "text",
      text: `The other modes: ${MODES.filter((mode) => mode !== page.mode)
        .map((mode) => `${mode} ${MODE_MEANING[mode]}`)
        .join("; ")}. ${EVERY_MODE}`,
    },
    ...SETTING_KEYS.flatMap((key): ApprovalBlock[] => {
      const name = (
        {
          judge: "Judge",
          plan: "Plan",
          planQuick: "Plan (quick)",
          run: "Run",
          guide: "Guide",
          items: "Items",
          gateReview: "Gate review",
          finalReview: "Final review",
          simplify: "Simplify",
        } satisfies Record<SettingKey, string>
      )[key];
      const setting = page.settings[key];
      const rows: ApprovalBlock[] = [
        {
          kind: "row",
          row: { kind: "setting", key },
          label: `${name} ${(ROLE_KEYS as readonly string[]).includes(key) ? "role" : "model"}`,
          value: setting.target,
        },
      ];
      if (key === "items")
        rows.push({
          kind: "row",
          row: { kind: "settingDeep", key },
          label: "Items deep role",
          value: setting.deep ?? "",
        });
      if (!thinkingLocked(key))
        rows.push({
          kind: "row",
          row: { kind: "settingThinking", key },
          label: `${name} thinking`,
          value: setting.thinking ?? "role default",
        });
      return rows;
    }),
    { kind: "heading", text: "Work items" },
  ];

  for (const item of handoff.items) {
    const tier = page.tiers[item.id] ?? item.tier;
    blocks.push({
      kind: "row",
      row: { kind: "tier", id: item.id },
      label: `${item.id} ${item.title}`,
      value: `tier: ${tier}`,
    });
    blocks.push({
      kind: "bullet",
      text: `Blocked by: ${item.blockedBy.length > 0 ? item.blockedBy.join(", ") : "none"}`,
    });
    blocks.push({ kind: "bullet", text: `New: ${item.adds}` });
    blocks.push({ kind: "bullet", text: `Owns: ${item.owns.join(", ")}` });
    blocks.push({
      kind: "bullet",
      text: acceptanceText(item.acceptance, item.acceptanceUnverified),
    });
    if (item.why) blocks.push({ kind: "bullet", text: `Why: ${item.why}` });
  }

  blocks.push({ kind: "heading", text: "Stops" });
  blocks.push(...handoff.stops.map((text) => ({ kind: "bullet" as const, text })));

  const caps = budgetCaps(handoff.budget);
  blocks.push({ kind: "heading", text: "Budget" });
  blocks.push({
    kind: "bullet",
    text: `Cost cap: $${handoff.budget.costCap}, over it is a deviation`,
  });
  blocks.push({
    kind: "bullet",
    text: `Lines: ${handoff.budget.lines} planned, ${caps.linesCap} is the stop (Lines × 1.5)`,
  });
  blocks.push({ kind: "bullet", text: `New files: ${handoff.budget.newFiles}` });
  blocks.push({ kind: "bullet", text: `New abstractions: ${handoff.budget.newAbstractions}` });
  blocks.push({ kind: "bullet", text: `Concurrency: ${handoff.budget.concurrency}` });

  blocks.push({ kind: "heading", text: "Open questions" });
  if (handoff.openQuestions.length === 0) blocks.push({ kind: "text", text: "None." });
  for (const question of handoff.openQuestions) {
    blocks.push({
      kind: "row",
      row: { kind: "question", id: question.id },
      label: `${question.id} ${question.text}`,
      value: page.answers[question.id]?.trim() || "unanswered",
    });
  }

  blocks.push({ kind: "heading", text: "Decision" });
  blocks.push({
    kind: "row",
    row: { kind: "approve" },
    label: "Approve and start the run",
    value: "",
  });
  blocks.push({
    kind: "row",
    row: { kind: "back" },
    label: "Send back to the plan with a note",
    value: "",
  });
  blocks.push({
    kind: "row",
    row: { kind: "cancel" },
    label: "Cancel, stay at the plan step",
    value: "",
  });
  return blocks;
};

/** `APPROVAL.md`: the page's blocks as Markdown, so what the owner read is on disk. */
export const approvalMarkdown = (blocks: readonly ApprovalBlock[]): string => {
  const rendered = blocks.map((block) => {
    switch (block.kind) {
      case "title":
        return `# ${block.text}`;
      case "heading":
        return `## ${block.text}`;
      case "text":
        return block.text;
      case "bullet":
        return `- ${block.text}`;
      case "row":
        return block.value === "" ? `- ${block.label}` : `- ${block.label} — ${block.value}`;
    }
  });
  return `${rendered.join("\n\n")}\n`;
};
