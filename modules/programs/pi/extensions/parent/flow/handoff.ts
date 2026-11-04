/**
 * The HANDOFF parser (C6): `HANDOFF.md` into the shape the approval page
 * renders, the judge reads and the run lead follows, with the line of every
 * field the page may rewrite.
 *
 * `handoff-format.md` is the grammar and `handoff-example.md` a file it accepts.
 * The parser reports every error it finds rather than the first, each with the
 * 1-based line it belongs to, so a refused approval says everything to fix at
 * once. It never throws: a plan is another model's text, and a bad one is data
 * about what to fix.
 */
import {
  type HandoffBudget,
  type HandoffContract,
  type HandoffDecision,
  type HandoffItem,
  type HandoffQuestion,
  ITEM_ID,
  type ParsedHandoff,
  type Tier,
} from "./contracts.ts";

export type HandoffError = { line: number; message: string };

export type ParseHandoffResult =
  | { ok: true; handoff: ParsedHandoff }
  | { ok: false; errors: HandoffError[] };

/** The `##` sections a plan must carry (C6). Anything else is kept, unread. */
export const REQUIRED_SECTIONS = [
  "Mission",
  "Smallest version",
  "Scope",
  "Context",
  "Locked decisions",
  "Work items",
  "Budget",
  "Stops",
] as const;

/** The `###` subsections of `## Locked decisions`; the third is optional. */
const DECISION_SECTIONS = ["Yours", "Defaults", "Mechanism uncertain"] as const;

/** An item's field bullets, in the order the format lists them. */
const ITEM_FIELDS = [
  "Blocked by",
  "Owns",
  "New",
  "Tier",
  "Outcome",
  "Acceptance",
  "Constraints",
  "Why",
] as const;

/** An item field every item must carry; `Why:` is the spike's extra. */
const REQUIRED_ITEM_FIELDS = [
  "Blocked by",
  "Owns",
  "New",
  "Tier",
  "Outcome",
  "Acceptance",
  "Constraints",
] as const;

/** A budget bullet's name, in the order the format lists them. */
const BUDGET_FIELDS = [
  "New files",
  "New abstractions",
  "Lines",
  "Cost cap",
  "Concurrency",
] as const;

/** One line and where it sits in the file (1-based), which is what an error names. */
type Line = { text: string; number: number };

/** One `##` section: its heading, and the lines under it up to the next heading. */
type Section = { heading: string; line: number; body: Line[] };

/** A top-level `- ` bullet with the indented lines that belong to it. */
type Bullet = { text: string; line: number; rest: Line[] };

/** One `###` subsection of a section. */
type Subsection = { name: string; line: number; body: Line[] };

/** A bullet's value: its own line joined with its continuation lines by single spaces. */
const valueOf = (bullet: Bullet): string =>
  [bullet.text, ...bullet.rest.map((line) => line.text.trim().replace(/^-\s+/, ""))]
    .filter(Boolean)
    .join(" ");

const withoutPeriod = (text: string): string => text.replace(/[.;]\s*$/, "").trim();

/** Every `##` section, in file order; text before the first one (the title) is not a section. */
const sectionsOf = (lines: readonly Line[]): Section[] => {
  const sections: Section[] = [];
  let current: Section | undefined;
  for (const line of lines) {
    const heading = /^##\s+(.+)$/.exec(line.text);
    if (heading) {
      current = { heading: heading[1].trim(), line: line.number, body: [] };
      sections.push(current);
      continue;
    }
    // A later `#` title ends the section: nothing under it belongs to the plan's sections.
    if (/^#\s/.test(line.text)) {
      current = undefined;
      continue;
    }
    current?.body.push(line);
  }
  return sections;
};

/**
 * The top-level bullets of a block and their continuation lines. A blank line is
 * skipped rather than ending a bullet: Markdown lets a paragraph that belongs to
 * a list item sit after one, and a plan writes its `Why:` there. A new bullet or
 * a prose line at the margin ends it, so an item's field never swallows the next
 * one.
 */
const bulletsOf = (lines: readonly Line[]): Bullet[] => {
  const bullets: Bullet[] = [];
  let current: Bullet | undefined;
  for (const line of lines) {
    if (line.text.trim() === "") continue;
    if (line.text.startsWith("- ")) {
      current = { text: line.text.slice(2).trim(), line: line.number, rest: [] };
      bullets.push(current);
      continue;
    }
    if (/^\s/.test(line.text) && current) {
      current.rest.push(line);
      continue;
    }
    current = undefined;
  }
  return bullets;
};

/** A section's `###` subsections; lines before the first one belong to no subsection. */
const subsectionsOf = (lines: readonly Line[]): Subsection[] => {
  const subsections: Subsection[] = [];
  let current: Subsection | undefined;
  for (const line of lines) {
    const heading = /^###\s+(.+)$/.exec(line.text);
    if (heading) {
      current = { name: heading[1].trim(), line: line.number, body: [] };
      subsections.push(current);
      continue;
    }
    current?.body.push(line);
  }
  return subsections;
};

/** The trimmed body of a section, for the `sections` map and the prose fields. */
const proseOf = (body: readonly Line[]): string =>
  body
    .map((line) => line.text.trimEnd())
    .join("\n")
    .trim();

/** The `- Field: value` split; a bullet with no colon is not a field bullet. */
const fieldOf = (bullet: Bullet): { name: string; value: string } | undefined => {
  const split = /^([^:]+):\s*(.*)$/.exec(bullet.text);
  if (!split) return undefined;
  const rest = [split[2], ...bullet.rest.map((line) => line.text.trim().replace(/^-\s+/, ""))]
    .filter(Boolean)
    .join(" ");
  return { name: split[1].trim(), value: rest.trim() };
};

/** The backticked paths in a value, or its comma-separated parts when nothing is backticked. */
const pathsOf = (value: string): string[] => {
  const quoted = [...value.matchAll(/`([^`]+)`/g)].map((match) => match[1].trim()).filter(Boolean);
  if (quoted.length > 0) return quoted;
  return value
    .split(",")
    .map((part) => part.replace(/[.;]\s*$/, "").trim())
    .filter(Boolean);
};

const isSpikeTitle = (title: string): boolean => /\(spike, timebox \d+\)\s*$/.test(title);

/**
 * `HANDOFF.md` into `ParsedHandoff`, or the errors that stop an approval (C6).
 * `errors` is sorted by line so a refusal reads top to bottom.
 */
export const parseHandoff = (text: string): ParseHandoffResult => {
  const errors: HandoffError[] = [];
  const fail = (line: number, message: string): void => {
    errors.push({ line, message });
  };

  const lines: Line[] = text.split(/\r?\n/).map((line, index) => ({
    text: line,
    number: index + 1,
  }));
  const sections: Section[] = sectionsOf(lines);
  const byHeading = new Map<string, Section>();
  for (const section of sections) {
    if (byHeading.has(section.heading))
      fail(section.line, `a second ## ${section.heading} section: each heading appears once`);
    else byHeading.set(section.heading, section);
  }
  for (const heading of REQUIRED_SECTIONS) {
    if (!byHeading.has(heading)) fail(1, `missing the required ## ${heading} section`);
  }

  const verbatim: Record<string, string> = {};
  for (const section of sections) verbatim[section.heading] = proseOf(section.body);

  // ── Mission ───────────────────────────────────────────────────────────────

  const missionSection = byHeading.get("Mission");
  const mission = missionSection ? proseOf(missionSection.body) : "";
  if (missionSection && mission === "")
    fail(missionSection.line, "## Mission is empty: say why this exists");

  // ── Smallest version ─────────────────────────────────────────────────────

  let smallestVersion = "";
  let notBuilding: string[] = [];
  const smallest = byHeading.get("Smallest version");
  if (smallest) {
    const at = smallest.body.findIndex((line) => /^Not building:/.test(line.text.trim()));
    if (at < 0) {
      fail(
        smallest.line,
        '## Smallest version needs a "Not building:" line followed by its bullets',
      );
    } else {
      smallestVersion = smallest.body
        .slice(0, at)
        .map((line) => line.text.trim())
        .filter(Boolean)
        .join(" ");
      const listed = bulletsOf(smallest.body.slice(at + 1))
        .map(valueOf)
        .filter(Boolean);
      const inline = smallest.body[at].text
        .trim()
        .replace(/^Not building:\s*/, "")
        .replace(/[.;]\s*$/, "")
        .trim();
      notBuilding = listed.length > 0 ? listed : inline ? [inline] : [];
      if (smallestVersion === "")
        fail(smallest.line, "## Smallest version needs its paragraph before Not building:");
      if (notBuilding.length === 0)
        fail(smallest.body[at].number, "Not building: needs at least one bullet");
    }
  }

  // ── Scope ─────────────────────────────────────────────────────────────────

  const scopeSection = byHeading.get("Scope");
  const scope = scopeSection ? proseOf(scopeSection.body) : "";
  if (scopeSection) {
    const body = scopeSection.body;
    const inAt = body.findIndex((line) => /^In:/.test(line.text.trim()));
    const outAt = body.findIndex((line) => /^Out:/.test(line.text.trim()));
    if (inAt < 0) fail(scopeSection.line, '## Scope needs an "In:" line');
    if (outAt < 0) fail(scopeSection.line, '## Scope needs an "Out:" line');
    if (inAt >= 0) {
      const until = outAt > inAt ? outAt : body.length;
      const inline = body[inAt].text
        .trim()
        .replace(/^In:\s*/, "")
        .trim();
      if (bulletsOf(body.slice(inAt + 1, until)).length === 0 && !inline)
        fail(body[inAt].number, "In: needs at least one bullet");
    }
    if (outAt >= 0) {
      const inline = body[outAt].text
        .trim()
        .replace(/^Out:\s*/, "")
        .trim();
      if (bulletsOf(body.slice(outAt + 1)).length === 0 && !inline)
        fail(body[outAt].number, "Out: needs at least one bullet, or a sentence saying what stays");
    }
  }

  // ── Locked decisions ──────────────────────────────────────────────────────

  const decisions: Record<"yours" | "defaults" | "uncertain", HandoffDecision[]> = {
    yours: [],
    defaults: [],
    uncertain: [],
  };
  const locked = byHeading.get("Locked decisions");
  if (locked) {
    const subsections = subsectionsOf(locked.body);
    const named = new Map<string, Subsection>();
    for (const subsection of subsections) {
      if (named.has(subsection.name))
        fail(subsection.line, `a second ### ${subsection.name} subsection`);
      else named.set(subsection.name, subsection);
      if (!(DECISION_SECTIONS as readonly string[]).includes(subsection.name))
        fail(
          subsection.line,
          `### ${subsection.name} is not one of ${DECISION_SECTIONS.join(", ")}`,
        );
    }
    for (const required of ["Yours", "Defaults"] as const) {
      if (!named.has(required))
        fail(locked.line, `## Locked decisions needs a ### ${required} subsection`);
    }
    const collect = (
      subsection: Subsection | undefined,
      kind: HandoffDecision["kind"],
      prefix: "U" | "D",
    ): HandoffDecision[] => {
      if (!subsection) return [];
      const found: HandoffDecision[] = [];
      const shape = new RegExp(`^${prefix}\\d+$`);
      for (const bullet of bulletsOf(subsection.body)) {
        const match = /^([A-Z]+\d+)\s+(.+)$/.exec(bullet.text);
        if (!match) {
          fail(bullet.line, `a decision is a bullet starting ${prefix}1, ${prefix}2, …`);
          continue;
        }
        const [, id, rest] = match;
        if (!shape.test(id)) {
          fail(bullet.line, `a decision in ### ${subsection.name} is ${prefix}<n>, not ${id}`);
          continue;
        }
        const tail = [rest, ...bullet.rest.map((line) => line.text.trim().replace(/^-\s+/, ""))]
          .filter(Boolean)
          .join(" ");
        found.push({ id, kind, text: tail.trim(), line: bullet.line });
      }
      return found;
    };
    decisions.yours = collect(named.get("Yours"), "yours", "U");
    decisions.defaults = collect(named.get("Defaults"), "default", "D");
    decisions.uncertain = collect(named.get("Mechanism uncertain"), "default", "D");
  }

  // ── Contracts ─────────────────────────────────────────────────────────────

  const contracts: HandoffContract[] = [];
  const contractsSection = byHeading.get("Contracts");
  if (contractsSection) {
    for (const bullet of bulletsOf(contractsSection.body)) {
      const value = valueOf(bullet);
      const match = /^(C\d+)\s+(.+)$/.exec(value);
      if (!match) {
        fail(bullet.line, "a contract is a bullet starting C1, C2, …");
        continue;
      }
      const [, id, body] = match;
      const colon = body.indexOf(": ");
      const name = withoutPeriod(colon < 0 ? body : body.slice(0, colon));
      const tail = colon < 0 ? "" : body.slice(colon + 2).trim();
      const whyAt = tail.indexOf("Why:");
      if (whyAt < 0) {
        fail(
          bullet.line,
          `${id} has no "Why:" reason: a contract that cannot say why is one to delete`,
        );
        continue;
      }
      const why = withoutPeriod(tail.slice(whyAt + "Why:".length));
      if (why === "") fail(bullet.line, `${id}'s "Why:" is empty`);
      contracts.push({
        id,
        name,
        shape: withoutPeriod(tail.slice(0, whyAt)),
        why,
        line: bullet.line,
      });
    }
  }

  // ── Work items ────────────────────────────────────────────────────────────

  type ItemFields = { id: string; title: string; line: number; fields: Map<string, Bullet> };
  const fieldsOf = new Map<string, ItemFields>();
  const itemsSection = byHeading.get("Work items");
  if (itemsSection) {
    const blocks: { heading: string; line: number; body: Line[] }[] = [];
    for (const line of itemsSection.body) {
      const heading = /^###\s+(.+)$/.exec(line.text);
      if (heading) {
        blocks.push({ heading: heading[1].trim(), line: line.number, body: [] });
        continue;
      }
      blocks.at(-1)?.body.push(line);
    }
    if (blocks.length === 0)
      fail(itemsSection.line, "## Work items has no ### <ID> <title> item under it");
    for (const block of blocks) {
      const heading = /^(\S+)\s+(.+)$/.exec(block.heading);
      if (!heading) {
        fail(
          block.line,
          `item heading "### ${block.heading}" is not "### <ID> <title>" with an ID of G<n>, A<n> or S<n>`,
        );
        continue;
      }
      const [, id, title] = heading;
      if (!ITEM_ID.test(id)) {
        fail(block.line, `item "${id}" is not an ID of G<n>, A<n> or S<n>`);
        continue;
      }
      if (fieldsOf.has(id)) {
        fail(block.line, `a second item with the ID ${id}`);
        continue;
      }
      const fields = new Map<string, Bullet>();
      for (const bullet of bulletsOf(block.body)) {
        const field = fieldOf(bullet);
        if (!field) {
          fail(bullet.line, `"${bullet.text}" is not a "- <Field>: <value>" bullet`);
          continue;
        }
        if (!(ITEM_FIELDS as readonly string[]).includes(field.name)) {
          fail(bullet.line, `"${field.name}" is not an item field`);
          continue;
        }
        if (fields.has(field.name)) {
          fail(bullet.line, `a second "- ${field.name}:" in item ${id}`);
          continue;
        }
        fields.set(field.name, bullet);
      }
      fieldsOf.set(id, { id, title: title.trim(), line: block.line, fields });
    }
  }

  const known = [...fieldsOf.keys()];
  const items: HandoffItem[] = [];
  for (const entry of fieldsOf.values()) {
    const { id } = entry;
    for (const required of REQUIRED_ITEM_FIELDS) {
      if (!entry.fields.has(required))
        fail(entry.line, `item ${id} has no "- ${required}:" bullet`);
    }
    const spike = isSpikeTitle(entry.title);
    if (spike && !entry.fields.has("Why"))
      fail(entry.line, `spike ${id} has no "- Why:" line: a spike that cannot say what it buys`);

    const read = (name: string): { value: string; line: number } | undefined => {
      const bullet = entry.fields.get(name);
      if (!bullet) return undefined;
      const field = fieldOf(bullet);
      if (!field) return undefined;
      if (field.value === "") fail(bullet.line, `item ${id}'s "- ${name}:" is empty`);
      return { value: field.value, line: bullet.line };
    };

    const blocked = read("Blocked by");
    let blockedBy: string[] = [];
    if (blocked) {
      if (/^none$/i.test(blocked.value)) blockedBy = [];
      else {
        blockedBy = blocked.value
          .split(",")
          .map((part) => part.trim())
          .filter(Boolean);
        for (const blocker of blockedBy) {
          if (blocker === id) fail(blocked.line, `item ${id} is blocked by itself`);
          else if (!ITEM_ID.test(blocker))
            fail(blocked.line, `"${blocker}" is not an ID of G<n>, A<n> or S<n>`);
          else if (!known.includes(blocker))
            fail(
              blocked.line,
              `item ${id} is blocked by ${blocker}, which this plan has no item for`,
            );
        }
      }
    }

    const owns = read("Owns");
    const owned = owns ? pathsOf(owns.value) : [];
    if (owns && owned.length === 0)
      fail(owns.line, `item ${id} owns no path: list the files it may change`);

    const tier = read("Tier");
    let itemTier: Tier = "flash";
    if (tier) {
      if (tier.value === "flash" || tier.value === "deep") itemTier = tier.value;
      else fail(tier.line, `Tier: ${JSON.stringify(tier.value)} is not flash or deep`);
    }

    const acceptance = read("Acceptance");
    const why = read("Why");

    items.push({
      id,
      title: entry.title,
      spike,
      blockedBy,
      owns: owned,
      adds: read("New")?.value ?? "",
      tier: itemTier,
      tierLine: entry.fields.get("Tier")?.line ?? 0,
      outcome: read("Outcome")?.value ?? "",
      acceptance: acceptance?.value ?? "",
      acceptanceUnverified: (acceptance?.value ?? "").trimEnd().endsWith("(unverified)"),
      constraints: read("Constraints")?.value ?? "",
      why: why?.value,
      line: entry.line,
    });
  }
  if (fieldsOf.size > 0) items.sort((left, right) => left.line - right.line);

  // ── Budget ────────────────────────────────────────────────────────────────

  const budget: HandoffBudget = {
    newFiles: 0,
    newAbstractions: 0,
    lines: 0,
    costCap: 0,
    concurrency: 0,
  };
  const budgetSection = byHeading.get("Budget");
  if (budgetSection) {
    const found = new Map<string, number>();
    for (const bullet of bulletsOf(budgetSection.body)) {
      const field = fieldOf(bullet);
      if (!field || !(BUDGET_FIELDS as readonly string[]).includes(field.name)) {
        fail(bullet.line, `"${bullet.text}" is not one of the five budget bullets`);
        continue;
      }
      if (found.has(field.name)) {
        fail(bullet.line, `a second "- ${field.name}:" in ## Budget`);
        continue;
      }
      // The number leads; a plan may say what it counted after it.
      const raw = /^\$?\s*(\d+(?:\.\d+)?)/.exec(field.value)?.[1];
      const value = raw === undefined ? Number.NaN : Number(raw);
      if (raw === undefined || !Number.isFinite(value)) {
        fail(
          bullet.line,
          `${field.name}: ${JSON.stringify(field.value)} does not start with a number`,
        );
        continue;
      }
      found.set(field.name, value);
    }
    for (const name of BUDGET_FIELDS) {
      if (!found.has(name)) fail(budgetSection.line, `## Budget has no "- ${name}:" bullet`);
    }
    budget.newFiles = found.get("New files") ?? 0;
    budget.newAbstractions = found.get("New abstractions") ?? 0;
    budget.lines = found.get("Lines") ?? 0;
    budget.costCap = found.get("Cost cap") ?? 0;
    budget.concurrency = found.get("Concurrency") ?? 0;
  }

  // ── Stops ─────────────────────────────────────────────────────────────────

  let stops: string[] = [];
  const stopsSection = byHeading.get("Stops");
  if (stopsSection) {
    stops = bulletsOf(stopsSection.body).map(valueOf).filter(Boolean);
    if (stops.length === 0)
      fail(stopsSection.line, "## Stops needs at least one bullet: what halts this run");
  }

  // ── Open questions ────────────────────────────────────────────────────────

  const openQuestions: HandoffQuestion[] = [];
  const questionsSection = byHeading.get("Open questions");
  if (questionsSection) {
    for (const bullet of bulletsOf(questionsSection.body)) {
      const match = /^(Q\d+)\s+(.+)$/.exec(bullet.text);
      if (!match) {
        fail(bullet.line, `an open question is a bullet starting Q1, Q2, …`);
        continue;
      }
      const [, id] = match;
      const text = valueOf(bullet)
        .replace(/^Q\d+\s+/, "")
        .trim();
      openQuestions.push({ id, text, line: bullet.line });
    }
  }

  if (errors.length > 0) {
    errors.sort((left, right) => left.line - right.line);
    return { ok: false, errors };
  }

  return {
    ok: true,
    handoff: {
      mission,
      smallestVersion,
      notBuilding,
      scope,
      context: verbatim.Context ?? "",
      yours: decisions.yours,
      defaults: decisions.defaults,
      uncertain: decisions.uncertain,
      items,
      contracts,
      budget,
      stops,
      openQuestions,
      amendments: verbatim.Amendments ?? "",
      sections: verbatim,
    },
  };
};
