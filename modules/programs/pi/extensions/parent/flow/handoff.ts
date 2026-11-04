/**
 * The HANDOFF parser (C6): `HANDOFF.md` into the shape the approval page
 * renders, the judge reads and the run lead follows, with the line of every
 * field the page may rewrite.
 *
 * G0 ships a stub: it refuses nothing and returns a one-item plan, so the
 * conductor can be built and its scenario can walk past the approve step
 * before A2 lands. A2 replaces this file with the real parser and its tests.
 */
import type { HandoffBudget, ParsedHandoff } from "./contracts.ts";

export type HandoffError = { line: number; message: string };

export type ParseHandoffResult =
  | { ok: true; handoff: ParsedHandoff }
  | { ok: false; errors: HandoffError[] };

const budget = (): HandoffBudget => ({
  newFiles: 1,
  newAbstractions: 0,
  lines: 100,
  costCap: 1,
  concurrency: 1,
});

/** The stub plan: enough for the conductor to advance, and honest about being one. */
const stub = (): ParsedHandoff => ({
  mission: "The stub handoff: A2 replaces this parser.",
  smallestVersion: "Nothing is built; the conductor only needs a plan that parses.",
  notBuilding: ["the real parser"],
  scope: "In:\n\n- nothing\n\nOut: everything",
  context: "- the parser is A2's",
  yours: [],
  defaults: [],
  uncertain: [],
  items: [
    {
      id: "A1",
      title: "The stub item",
      spike: false,
      blockedBy: [],
      owns: [],
      adds: "nothing",
      tier: "flash",
      tierLine: 1,
      outcome: "The conductor advances through the approve step.",
      acceptance: "nothing to accept (unverified)",
      acceptanceUnverified: true,
      constraints: "C6",
      line: 1,
    },
  ],
  contracts: [],
  budget: budget(),
  stops: [],
  openQuestions: [],
  amendments: "",
  sections: {},
});

/** `HANDOFF.md` into `ParsedHandoff`, or the errors that stop an approval (C6). */
export const parseHandoff = (_text: string): ParseHandoffResult => ({ ok: true, handoff: stub() });
