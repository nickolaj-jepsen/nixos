import { expect, test } from "claude-code/testing";

import {
  answer,
  type Form,
  go,
  isReview,
  newDraft,
  parse,
  placeReply,
  reply,
  setNote,
} from "../hooks/core";
import * as fx from "./fixtures";

/** `label[option keys*recommended key]`, a bare `*` for a recommendation naming no option. */
const shape = (form: Form | null) =>
  form === null
    ? "null"
    : [
        form.kind,
        ...form.items.map((it) => {
          const keys = it.options.map((o) => o.key).join(form.kind === "picks" ? "," : "");
          const rec =
            it.recommendedOption !== undefined
              ? `*${it.options[it.recommendedOption]?.key}`
              : it.recommended !== undefined
                ? "*"
                : "";
          return `${it.label}[${keys}${rec}]`;
        }),
      ].join(" ");

const must = <T>(value: T | null | undefined): T => {
  if (value === null || value === undefined) throw new Error("expected a value");
  return value;
};

const itemsOf = (text: string) => must(parse(text)).items;

test("each fixture parses to its shape", () => {
  const cases: [string, string][] = [
    [fx.grillingRound, "round Q1[ABC*A] Q2[*] Q3[AB]"],
    [fx.roundAfterResearch, "round Q19[*] Q25[*]"],
    [fx.numberedQuestions, "round 1[] 2[*] 3[*]"],
    [fx.singleQuestion, "round Q18[*]"],
    [fx.myRecommendation, "round Q4[*]"],
    [fx.leanToward, "round Q10[ABC*C]"],
    [
      fx.ideateSummary,
      "picks 1[build*build] 2[build,/brainstorm*/brainstorm] 3[build,/grill-me*/grill-me]",
    ],
    [fx.mineSummary, "picks 1[build*build] 2[build,/grill-me*/grill-me]"],
    [fx.plainList, "null"],
    [fx.fencedFormat, "null"],
  ];
  for (const [text, expected] of cases) expect(shape(parse(text))).toBe(expected);
});

test("a question keeps its context and drops what the form draws itself", () => {
  const round = itemsOf(fx.grillingRound);
  const q1 = must(round[0]);
  const q2 = must(round[1]);
  expect(q1.title).toBe(
    'Should every focus default to "worth doing, ranked by payoff per effort"?',
  );
  expect(must(q1.options[1]).text).toBe(
    'Default by kind: features get "worth doing", refactors keep big swings.',
  );
  expect(q1.body).toBe("");
  expect(q2.recommended).toBe(
    "Yes. Each run threw away about 85% of its candidates, and four generators still give 20–24.",
  );
  const first = must(itemsOf(fx.numberedQuestions)[0]);
  expect(first.title).toBe("What should it do for you?");
  expect(first.body).toBe("Help you discover things, or warn you about state?");
  expect(must(itemsOf(fx.roundAfterResearch)[0]).body).toContain("| Hotspots | churn × size |");
});

test("a bold option title leaves its prose as detail", () => {
  const options = must(itemsOf(fx.leanToward)[0]).options;
  const a = must(options[0]);
  const b = must(options[1]);
  expect(a.text).toBe("Read-only page (my recommendation for v1).");
  expect(a.detail).toBe("Steering stays in the tracker.");
  expect(b.text).toBe("Interactive page:");
});

test("a pick keeps its title apart from its fields", () => {
  const picks = itemsOf(fx.mineSummary);
  const one = must(picks[0]);
  const two = must(picks[1]);
  expect(one.title).toBe("The default bar cuts the ideas you act on");
  expect(one.body).toBe("2/3 · S · build");
  expect(must(itemsOf(fx.ideateSummary)[1]).title).toBe(
    "Bench real clients by replaying their frames",
  );
  expect(two.recommended).toBe("route it to /grill-me");
});

test("answering steps through the items to the review", () => {
  const form = must(parse(fx.grillingRound));
  let d = newDraft(form);
  d = answer(form, d, { kind: "option", index: 1 });
  expect(d.step).toBe(1);
  d = answer(form, d, { kind: "accept" });
  expect(d.step).toBe(2);
  // Q3 recommends nothing, so there is nothing to accept.
  expect(answer(form, d, { kind: "accept" })).toEqual(d);
  d = answer(form, d, { kind: "text", text: "  keep it  " });
  expect(isReview(form, d)).toBe(true);
  expect(go(form, d, 99).step).toBe(3);
  expect(go(form, d, -1).step).toBe(0);
  expect(reply(form, d)).toBe("Q1: B\nQ2: yes\nQ3: keep it");
});

test("a round of recommendations collapses to yes, unless something else is said", () => {
  const form = must(parse(fx.roundAfterResearch));
  let d = newDraft(form);
  d = answer(form, d, { kind: "accept" });
  d = answer(form, d, { kind: "accept" });
  expect(reply(form, d)).toBe("yes");
  expect(reply(form, setNote(form, d, "also look at subtraction"))).toBe(
    "Q19: yes\nQ25: yes\nalso look at subtraction",
  );
});

test("a skipped question stays out of the reply; a note rides on its answer", () => {
  const form = must(parse(fx.grillingRound));
  let d = newDraft(form);
  // Picking the recommended letter is still the recommendation.
  d = answer(form, d, { kind: "option", index: 0 });
  d = setNote(form, go(form, d, 0), "but keep the flag");
  d = go(form, d, 2);
  d = answer(form, d, { kind: "option", index: 1 });
  expect(reply(form, d)).toBe("Q1: A — but keep the flag\nQ3: B");
  expect(reply(form, newDraft(form))).toBe("");
});

test("picks group the builds and route the rest", () => {
  const form = must(parse(fx.ideateSummary));
  let d = newDraft(form);
  d = answer(form, d, { kind: "accept" });
  d = answer(form, d, { kind: "option", index: 0 });
  d = answer(form, d, { kind: "accept" });
  expect(reply(form, d)).toBe("do 1, 2\n3 → /grill-me");

  let e = newDraft(form);
  e = answer(form, e, { kind: "accept" });
  e = setNote(form, go(form, e, 0), "measure first");
  e = go(form, e, 1);
  e = answer(form, e, { kind: "text", text: "merge with 3" });
  expect(reply(form, e)).toBe("do 1 — measure first\n2: merge with 3");
});

test("the reply goes above a draft, never over it", () => {
  expect(placeReply("", "yes")).toBe("yes");
  expect(placeReply("and one more thing", "yes")).toBe("yes\n\nand one more thing");
});
