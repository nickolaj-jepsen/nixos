/**
 * Turn endings in the shapes agents really write them, as seen across past
 * Claude Code and pi sessions (mine's sessions.py); the wording is made up.
 */

/** grilling's format: lettered options, a blockquoted recommendation per question. */
export const grillingRound = `The bar and the funnel are independent, so this round asks both.

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

/** Research and a table before the round; bodies hold numbered lists of their own. */
export const roundAfterResearch = `I looked at how other tools keep ideas diverse:
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

/** Numbered questions after a numbered list of ideas that asks nothing. */
export const numberedQuestions = `## Ideas, grouped by what they're for

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

/** One question, its proposal in the bold title. */
export const singleQuestion = `**Q18: What should the agent do with each note? I propose: it folds the note into the plan and removes it.**

The alternative is to answer everything in chat and keep the file clean.

> **Recommended:** yes. The file is the conversation.`;

/** The legacy one-question format: a recommendation heading over bullets, then "Agree?". */
export const myRecommendation = `**Q4. What happens when you tap an app while the VM is off?**

The VM dies with the app's process, so this is common.

**My recommendation:**
- **The app list is cached**, so the launcher works with the VM off.
- **A tap starts the VM**, with a splash while it boots.

Agree?`;

/** Options with bold titles and prose after them; the lean comes in the closing text. */
export const leanToward = `**Q10. The live interface: read-only, or can people steer?**

- **A. Read-only page (my recommendation for v1).** Steering stays in the tracker.
- **B. Interactive page:** steer, abort and approve from the UI.
- **C. Read-only plus a few buttons**, mirrored as tracker comments.

I lean toward **C**: it's A with the controls you'll want the first time an agent loops. Which do you want?`;

/** ideate's chat summary before the one-line format: the route ends each item. */
export const ideateSummary = `3 ideas, saved to \`~/notes/ideas/IDEAS.md\`

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

/** The one-line summary ideate and mine share. */
export const mineSummary = `2 findings from 4 runs, saved to \`~/notes/FINDINGS.md\`

1. The default bar cuts the ideas you act on · 2/3 · S · build
2. The funnel is wide and slow for what survives · 3/3 · M · /grill-me

**Top pick: 1.** Make "worth doing" the default bar.`;

/** A numbered list that asks nothing. */
export const plainList = `Done. What changed:

1. The parser takes \`Q\` labels and numbers.
2. The review screen fills the prompt.

Tests pass.`;

/** A round's format quoted inside a fence is not a round. */
export const fencedFormat =
  "Format a round like so:\n\n```\n**Q1. <question>**\n\n> **Recommended:** <answer>\n```\n\nThat's the whole format.";
