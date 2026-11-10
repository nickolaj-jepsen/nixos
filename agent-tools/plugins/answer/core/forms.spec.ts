import { describe, expect, test } from "vitest";

import {
  type Action,
  apply,
  type Draft,
  entries,
  type Form,
  go,
  type Held,
  isReview,
  newDraft,
  offer,
  parse,
  reply,
  step,
  view,
  viewOf,
} from "./forms.ts";

// Turn endings in the shapes agents really write them, as seen across past Claude Code and pi
// sessions; the wording is made up.

// grilling's format: lettered options, a blockquoted recommendation per question.
const GRILLING_ROUND = `The bar and the funnel are independent, so this round asks both.

**Q1. Should every focus default to "worth doing, ranked by payoff per effort"?**

- **A.** Yes, one default for every kind. Big swings become an opt-in flag.
- **B.** Default by kind: features get "worth doing", refactors keep big swings.
- **C.** Add the bar as a second pick to the scope question.

> **Recommended:** A. A per-kind table is one more thing to keep in sync.

---

**Q2. Lower the per-generator target from 8–10 ideas to 5–6?**

> **Recommended:** Yes. Each run threw away about 85% of its candidates,
> and four generators still give 20–24.

---

**Q3. What should happen to \`--quick\`?**

- **A.** Drop it.
- **B.** Keep it as an alias.`;

// Research and a table before the round; bodies hold numbered lists of their own.
const ROUND_AFTER_RESEARCH = `I looked at how other tools keep ideas diverse:
- rotating methods from different categories;
- several critics rather than one.

1. Hotspots are churn × complexity.
2. Change coupling exposes hidden dependencies.

---

**Q19. Should the lenses come from this menu?**

| Lens | Asks |
|---|---|
| Hotspots | churn × size |
| Subtraction | what if X didn't exist |

The default trio per kind:
1. general: hotspots, subtraction, leverage;
2. perf: measure-first, hotspots.

> **Recommended:** Yes. It covers every kind of ask the mining found.

---

**Q25. Should the default be big swings, with \`--quick\` for the small bar?**

> **Recommended:** Yes. You said you'd almost always want big swings.

Sources: [one](https://example.com/one), [two](https://example.com/two).`;

// Numbered questions after a numbered list of ideas that asks nothing.
const NUMBERED_QUESTIONS = `## Ideas, grouped by what they're for

**1. Reminding you what you have**
- A hint of the day, weighted by neglect.

**2. Repo state worth knowing**
- Other agents already running in this repo.

## Questions before I propose approaches

1. **What should it do for you?** Help you discover things, or warn you about state?

2. **Who should see it?**
   > **Recommended:** both. A short motd for you, the hints for the model.

3. **How much space should it take?**
   > **Recommended:** one to three lines, and nothing when there's nothing to say.`;

// One question, its proposal in the bold title.
const SINGLE_QUESTION = `**Q18: What should the agent do with each note? I propose: it folds the note into the plan and removes it.**

The alternative is to answer everything in chat and keep the file clean.

> **Recommended:** yes. The file is the conversation.`;

// The legacy one-question format: a recommendation heading over bullets, then "Agree?".
const MY_RECOMMENDATION = `**Q4. What happens when you tap an app while the VM is off?**

The VM dies with the app's process, so this is common.

**My recommendation:**
- **The app list is cached**, so the launcher works with the VM off.
- **A tap starts the VM**, with a splash while it boots.

Agree?`;

// Options with bold titles and prose after them; the lean comes in the closing text.
const LEAN_TOWARD = `**Q10. The live interface: read-only, or can people steer?**

- **A. Read-only page (my recommendation for v1).** Steering stays in the tracker.
- **B. Interactive page:** steer, abort and approve from the UI.
- **C. Read-only plus a few buttons**, mirrored as tracker comments.

I lean toward **C**: it's A with the controls you'll want the first time an agent loops. Which do you want?`;

// ideate's chat summary before the one-line format: the route ends each item.
const IDEATE_SUMMARY = `3 ideas, saved to \`~/notes/ideas/IDEAS.md\`

1. Sample clocks throughout each bench run
   Explains the biggest unexplained number.
   Small, build it.
2. **Bench real clients by replaying their frames**
   Synthetic content already misled one idea.
   Medium, brainstorm first.
3. Keep fence waits outside the session lock
   The main thread takes the same lock on every touch.
   Small, grill first.

- The verifier rated idea 3 weak; I kept it, ranked last.

Start with 1: its result decides whether idea 3 is worth doing.`;

// The one-line summary ideate and mine share.
const MINE_SUMMARY = `2 findings from 4 runs, saved to \`~/notes/FINDINGS.md\`

1. The default bar cuts the ideas you act on · 2/3 · S · build
2. The funnel is wide and slow for what survives · 3/3 · M · /grill-me

**Top pick: 1.** Make "worth doing" the default bar.`;

// A numbered list that asks nothing.
const PLAIN_LIST = `Done. What changed:

1. The parser takes \`Q\` labels and numbers.
2. The review screen fills the prompt.

Tests pass.`;

// A round's format quoted inside a fence is not a round.
const FENCED_FORMAT =
  "Format a round like so:\n\n```\n**Q1. <question>**\n\n> **Recommended:** <answer>\n```\n\nThat's the whole format.";

/** `label[option keys*recommended key]`, a bare `*` for a recommendation naming no option. */
function shape(form: Form | null): string {
  if (!form) return "null";
  const one = (item: Form["items"][number]) => {
    const keys = item.options.map((option) => option.key).join(form.kind === "picks" ? "," : "");
    if (item.recommendedOption !== undefined)
      return `${item.label}[${keys}*${item.options[item.recommendedOption]?.key}]`;
    return `${item.label}[${keys}${item.recommended !== undefined ? "*" : ""}]`;
  };
  return [form.kind, ...form.items.map(one)].join(" ");
}

function formOf(text: string): Form {
  const form = parse(text);
  if (!form) throw new Error("the text asks nothing");
  return form;
}

const steps = (form: Form, actions: Action[], start?: Draft) =>
  actions.reduce((draft, action) => apply(form, draft, action), start ?? newDraft(form));

const pick = (entry: number): Action => ({ do: "pick", entry });
const toggle = (entry: number): Action => ({ do: "toggle", entry });
const note = (text: string): Action => ({ do: "note", text });
const write = (text: string): Action => ({ do: "write", text });
const FORWARD: Action = { do: "forward" };
const NEXT: Action = { do: "next" };
const ACCEPT: Action = { do: "accept" };
const REVIEW: Action = { do: "review" };

const itemOf = (form: Form, draft: Draft) => {
  const { item } = view(form, draft);
  if (!item) throw new Error("the review shows no item");
  return item;
};

describe("parse", () => {
  test.each([
    [GRILLING_ROUND, "round Q1[ABC*A] Q2[*] Q3[AB]"],
    [ROUND_AFTER_RESEARCH, "round Q19[*] Q25[*]"],
    [NUMBERED_QUESTIONS, "round 1[] 2[*] 3[*]"],
    [SINGLE_QUESTION, "round Q18[*]"],
    [MY_RECOMMENDATION, "round Q4[*]"],
    [LEAN_TOWARD, "round Q10[ABC*C]"],
    [
      IDEATE_SUMMARY,
      "picks 1[build*build] 2[build,/brainstorm*/brainstorm] 3[build,/grill-me*/grill-me]",
    ],
    [MINE_SUMMARY, "picks 1[build*build] 2[build,/grill-me*/grill-me]"],
    [PLAIN_LIST, "null"],
    [FENCED_FORMAT, "null"],
  ])("each ending parses to its shape (%#)", (text, expected) => {
    expect(shape(parse(text))).toBe(expected);
  });

  test("a question keeps its context and drops what the form draws itself", () => {
    const [q1, q2] = formOf(GRILLING_ROUND).items;
    expect(q1?.title).toBe(
      'Should every focus default to "worth doing, ranked by payoff per effort"?',
    );
    expect(q1?.options[1]?.text).toBe(
      'Default by kind: features get "worth doing", refactors keep big swings.',
    );
    expect(q1?.body).toBe("");
    expect(q2?.recommended).toBe(
      "Yes. Each run threw away about 85% of its candidates, and four generators still give 20–24.",
    );
    const first = formOf(NUMBERED_QUESTIONS).items[0];
    expect(first?.title).toBe("What should it do for you?");
    expect(first?.body).toBe("Help you discover things, or warn you about state?");
    expect(formOf(ROUND_AFTER_RESEARCH).items[0]?.body).toContain("| Hotspots | churn × size |");
  });

  test("a label bolded apart from its title keeps the whole title", () => {
    const options = "- **A.** Yes\n- **B.** No\n\n";
    const form = formOf(
      `**Q1.** **Should X?**\n\n${options}**Q2.** Use **bold** word here?\n\n${options}`,
    );
    expect(form.items.map((item) => item.title)).toEqual(["Should X?", "Use bold word here?"]);
  });

  test("a bold option title leaves its prose as detail", () => {
    const [a, b] = formOf(LEAN_TOWARD).items[0]?.options ?? [];
    expect(a?.text).toBe("Read-only page (my recommendation for v1).");
    expect(a?.detail).toBe("Steering stays in the tracker.");
    expect(b?.text).toBe("Interactive page:");
  });

  test("a pick keeps its title apart from its fields", () => {
    const [one, two] = formOf(MINE_SUMMARY).items;
    expect(one?.title).toBe("The default bar cuts the ideas you act on");
    expect(one?.body).toBe("2/3 · S · build");
    expect(formOf(IDEATE_SUMMARY).items[1]?.title).toBe(
      "Bench real clients by replaying their frames",
    );
    expect(two?.recommended).toBe("route it to /grill-me");
  });

  test("reads a pick said in passing", () => {
    const options = "- **A.** Flatten it.\n- **B.** Keep the grouping.\n";
    for (const text of [
      `**Q1. Which?**\n\nI'd go with A, since B buys nothing.\n\n${options}`,
      "**Q1. Which?**\n\n- **A.** Flatten it (my pick, and the smaller change).\n- **B.** Keep it.\n",
    ])
      expect(formOf(text).items[0]?.recommendedOption).toBe(0);
  });

  test("line endings from another system parse the same", () => {
    expect(shape(parse(GRILLING_ROUND.replaceAll("\n", "\r\n")))).toBe(
      shape(parse(GRILLING_ROUND)),
    );
  });
});

describe("apply", () => {
  test("answering steps through the items to the review", () => {
    const form = formOf(GRILLING_ROUND);
    let draft = steps(form, [pick(1), FORWARD]);
    expect(draft.step).toBe(1);
    // Q3 recommends nothing, so its entries are its options and a write-in.
    draft = steps(form, [pick(0), FORWARD, write("  keep it  ")], draft);
    expect(isReview(form, draft)).toBe(true);
    expect(go(form, draft, 99).step).toBe(3);
    expect(go(form, draft, -1).step).toBe(0);
    expect(reply(form, draft)).toBe("Q1: B\nQ2: yes\nQ3: keep it");
  });

  test("picking a write-in records nothing until it is written", () => {
    const form = formOf(GRILLING_ROUND);
    const writeIn = entries(form.items[0]!).length - 1;
    expect(steps(form, [pick(writeIn)])).toEqual(newDraft(form));
  });

  test("a round of recommendations collapses to yes unless something else is said", () => {
    const form = formOf(ROUND_AFTER_RESEARCH);
    const draft = steps(form, [pick(0), FORWARD, pick(0), FORWARD]);
    expect(reply(form, draft)).toBe("yes");
    expect(reply(form, apply(form, draft, note("also look at subtraction")))).toBe(
      "Q19: yes\nQ25: yes\nOverall: also look at subtraction",
    );
  });

  test("a skipped question stays out of the reply and a note rides on its answer", () => {
    const form = formOf(GRILLING_ROUND);
    // Picking the recommended letter is still the recommendation.
    const draft = steps(form, [
      pick(0),
      note("but keep the flag"),
      FORWARD,
      { do: "skip" },
      pick(1),
    ]);
    expect(reply(form, draft)).toBe("Q1: A\n    Note: but keep the flag\nQ3: B");
    // A note with no answer says so, so it can't read as a write-in.
    expect(reply(form, steps(form, [note("depends on Q3")]))).toBe(
      "Q1: no answer yet\n    Note: depends on Q3",
    );
    expect(reply(form, newDraft(form))).toBe("");
  });

  test("picks group the builds and route the rest", () => {
    const form = formOf(IDEATE_SUMMARY);
    const draft = steps(form, [pick(0), FORWARD, pick(0), FORWARD, pick(1), FORWARD]);
    expect(reply(form, draft)).toBe("do 1, 2\n3 → /grill-me");
    const other = steps(form, [pick(0), note("measure first"), FORWARD, write("merge with 3")]);
    expect(reply(form, other)).toBe("do 1\n    Note: measure first\n2: merge with 3");
  });

  test("going on finds the next item unanswered and then the review", () => {
    const form = formOf(GRILLING_ROUND);
    const answer = (entry: number) => [pick(entry), NEXT];
    let draft = steps(form, [FORWARD, ...answer(0)]);
    expect(draft.step).toBe(2);
    // Nothing is left after Q3, so it looks from the top; with nothing there either, the review.
    draft = apply(form, draft, write("keep"));
    expect(draft.step).toBe(0);
    expect(isReview(form, steps(form, answer(1), draft))).toBe(true);
    // A pick that stayed for its note goes on the same way; the review has nowhere to go.
    expect(steps(form, [pick(0), NEXT]).step).toBe(1);
    expect(isReview(form, steps(form, [REVIEW, NEXT]))).toBe(true);
    // An empty write-in clears and stays.
    expect(steps(form, [write(" ")]).step).toBe(0);
  });

  test("several options toggle into one answer", () => {
    const form = formOf(GRILLING_ROUND);
    const draft = steps(form, [pick(2), toggle(0)]);
    expect(draft.step).toBe(0);
    const shown = view(form, draft);
    expect(shown.item?.entries.map((entry) => entry.isChosen)).toEqual([true, false, true, false]);
    expect(shown.item?.isSeveral).toBe(true);
    expect(reply(form, draft)).toBe("Q1: A, C");
    expect(shown.review[0]?.shown.startsWith("A, C: ")).toBe(true);
    expect(reply(form, steps(form, [toggle(0), toggle(0)]))).toBe("");
    // A write-in, or a pick list's routes, are not for toggling.
    expect(steps(form, [toggle(3)])).toEqual(newDraft(form));
    const picks = formOf(IDEATE_SUMMARY);
    expect(steps(picks, [FORWARD, toggle(0)])).toEqual(steps(picks, [FORWARD]));
  });

  test("a recommendation naming several letters is accepted as all of them", () => {
    const options = [..."ABCDEF"].map((letter) => `- **${letter}.** Item ${letter}.\n`).join("");
    for (const [saying, keys] of [
      ["A, B and D now; C is cosmetic and E can wait.", "A, B, D"],
      ["A through C now; F goes to later.", "A, B, C"],
      ["**A** and **C**.", "A, C"],
    ] as const) {
      const form = formOf(`**Q1. Which go in?**\n\n${options}\n> **Recommended:** ${saying}\n`);
      const item = itemOf(form, newDraft(form));
      expect(item.isSeveral && item.canAccept).toBe(true);
      expect(
        item.entries
          .filter((entry) => entry.isRecommended)
          .map((entry) => entry.text[0])
          .join(""),
      ).toBe(keys.replaceAll(", ", ""));
      expect(reply(form, steps(form, [toggle(0)]))).toBe("Q1: A");
      expect(reply(form, steps(form, [ACCEPT]))).toBe("yes");
      expect(reply(form, steps(form, [ACCEPT, toggle(5)]))).toBe(`Q1: ${keys}, F`);
    }
    // One letter is still one pick, and a sentence that starts on "A" names none.
    const single = formOf(GRILLING_ROUND);
    expect(reply(single, steps(single, [ACCEPT])).slice(0, 5)).toBe("Q1: A");
    expect(itemOf(single, newDraft(single)).isSeveral).toBe(false);
    expect(steps(single, [FORWARD, FORWARD, ACCEPT])).toEqual(steps(single, [FORWARD, FORWARD]));
  });

  test("what cannot apply changes nothing and an unknown word is refused", () => {
    const form = formOf(GRILLING_ROUND);
    expect(steps(form, [pick(99)])).toEqual(newDraft(form));
    // The review shows no item to write an answer for.
    expect(steps(form, [REVIEW, write("late")])).toEqual(steps(form, [REVIEW]));
    expect(() => steps(form, [{ do: "explode" } as unknown as Action])).toThrow("no such action");
  });
});

describe("view", () => {
  test("says all a surface draws of an item", () => {
    const form = formOf(GRILLING_ROUND);
    const shown = view(form, steps(form, [pick(1)]));
    expect([shown.title, shown.count, shown.answered, shown.isReview]).toEqual([
      "Answer 3 questions",
      3,
      1,
      false,
    ]);
    const rows = shown.item?.entries ?? [];
    expect(rows.map((entry) => entry.kind)).toEqual(["option", "option", "option", "write"]);
    expect(rows[1]?.text).toBe(
      'B. Default by kind: features get "worth doing", refactors keep big swings.',
    );
    expect(rows.map((entry) => entry.isRecommended)).toEqual([true, false, false, false]);
    expect(rows.map((entry) => entry.isChosen)).toEqual([false, true, false, false]);
    expect(shown.item?.start).toBe(1);
  });

  test("starts on the recommendation and words a review", () => {
    const form = formOf(GRILLING_ROUND);
    expect(itemOf(form, newDraft(form)).start).toBe(0);
    expect(itemOf(form, steps(form, [FORWARD])).entries[0]?.text.slice(0, 4)).toBe("Yes:");
    const review = view(form, steps(form, [pick(1), FORWARD, FORWARD, write("keep"), REVIEW]));
    expect(review.item).toBeNull();
    expect(review.isReview).toBe(true);
    expect(review.review.map((row) => row.isAnswered)).toEqual([true, false, true]);
    expect(review.review[2]?.shown).toBe('"keep"');
  });

  test("shows why an option is recommended", () => {
    const form = formOf(GRILLING_ROUND);
    expect(itemOf(form, newDraft(form)).recommended.startsWith("A. ")).toBe(true);
    // With no options the recommendation is the accept entry, not said twice.
    expect(itemOf(form, steps(form, [FORWARD])).recommended).toBe("");
  });

  test("a recommendation beside options is said and never an entry", () => {
    const form = formOf(
      "**Q1. Which go in?**\n\n- **A.** Log.\n- **B.** Cooldown.\n- **C.** Canary.\n\n> **Recommended:** A and B now, C later.\n",
    );
    const item = itemOf(form, newDraft(form));
    expect(item.entries.map((entry) => entry.kind)).toEqual([
      "option",
      "option",
      "option",
      "write",
    ]);
    expect(item.recommended).toBe("A and B now, C later.");
    expect(item.canSeveral).toBe(true);
  });

  test("is plain data a harness can keep between turns", () => {
    const form = formOf(GRILLING_ROUND);
    const shown = view(form, steps(form, [pick(1), note("why")]));
    expect(JSON.parse(JSON.stringify(shown))).toEqual(shown);
  });
});

describe("what a session holds", () => {
  const held = (text: string, was: Held | null = null) => {
    const now = offer(was, text);
    if (!now) throw new Error("nothing is held");
    return now;
  };

  test("a new round replaces the form and the same one keeps its answers", () => {
    const answered = step(held(GRILLING_ROUND), pick(1));
    expect(viewOf(offer(answered, GRILLING_ROUND))?.answered).toBe(1);
    expect(viewOf(offer(answered, MINE_SUMMARY))?.answered).toBe(0);
  });

  test("a turn that asks nothing leaves the round waiting", () => {
    const answered = step(held(GRILLING_ROUND), pick(1));
    expect(viewOf(offer(answered, PLAIN_LIST))?.answered).toBe(1);
    expect(offer(null, PLAIN_LIST)).toBeNull();
  });

  test("a step aimed at an older form lands on nothing", () => {
    const old = viewOf(held(GRILLING_ROUND))?.id;
    const next = held(MINE_SUMMARY, held(GRILLING_ROUND));
    expect(viewOf(step(next, pick(0), old))?.answered).toBe(0);
    expect(viewOf(step(next, pick(0), viewOf(next)?.id))?.answered).toBe(1);
  });

  test("the same round is named the same, and another differently", () => {
    expect(viewOf(held(GRILLING_ROUND))?.id).toBe(viewOf(held(GRILLING_ROUND))?.id);
    expect(viewOf(held(GRILLING_ROUND))?.id).not.toBe(viewOf(held(LEAN_TOWARD))?.id);
    expect(viewOf(held(GRILLING_ROUND))?.id).toMatch(/^[0-9a-f]{16}$/);
  });
});
