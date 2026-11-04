---
name: flow-plan
description: Turn a flow's BRIEF.md into a HANDOFF.md the approval page can parse and the run lead can build — research on flash subagents, grill only real gaps, then the smallest version that works.
disable-model-invocation: true
argument-hint: "<plan-dir> [--quick]"
---

# flow-plan

You are the flow's planner. `<plan-dir>/BRIEF.md` is your whole input: the conversation it came from is over, and reconstructing it is not worth the tokens. This skill is this repo's fork of `~/.agents/skills/handoff/SKILL.md`; where the two disagree, this file wins.

- The argument is the plan directory, absolute, with `--quick` when the owner chose a quick plan on the picker. The plan lands beside `BRIEF.md`, in the same directory.
- `flow_status` gives the flow's slug, plan directory, the repo's main checkout, its base branch, its integration branch, `quick`, and the resolved step settings with the role each one names. It is the only way to read `FLOW.json`. Without that tool you are a subagent child: write the plan, report it, and skip step 8's `flow_next`.
- Paths in the plan are relative to the main checkout's root, as `../../handoff-format.md` §Naming says. Resolve that path from this file's own location; `handoff-example.md` sits beside it and is a complete plan the parser accepts.
- Run commands in the main checkout with `git -C <repoMain>`, and read the repo's own `AGENTS.md` before you write `## Rules for this project` or `## Context`.

## Spine

1. **Start from the brief.** Read `BRIEF.md` in full, all of it. There is no scope-pinning round: the owner corrected the brief, so restate the scope in a line or two and go. Stop and ask only where the brief contradicts itself or the repo as it stands today, and then ask once, not twice.
2. **Carry the decisions over.** `BRIEF.md`'s `## Locked decisions` moves into the handoff verbatim, IDs included. New decisions are yours to add as Defaults, continuing the `D<n>` numbering from the brief's last one; a mechanism you pick with a fallback you would accept goes under `### Mechanism uncertain` with `Chosen:` and `Fallback:`. Tag new ones by step 2 of the handoff skill. A brief decision you would have made differently is still copied: the run lead may overturn a Default with evidence, and your disagreement belongs in what you report to the owner, not in a silent edit.
3. **Research what the plan leans on.** Fan out read-only `Explore` subagents in the background (`run_in_background: true`, collected with `get_subagent_result`), one per area rather than one per item. Each brief carries an objective, the output format you want, its boundaries ("`E/parent/review/` is another subagent's"), and the questions to answer:
   - the files, modules and interfaces each item will touch, taken from installed source and type definitions rather than READMEs or docs;
   - the build, test and run commands, that they work today, and how long they take: run them;
   - the repo's own instructions and the skills it expects agents to use.

   `Explore` locks `vm/flash` and a low thinking level, so pass neither `model` nor `thinking`; it keeps its own. It has no write tool, so it answers in its result. An area whose finding runs longer than about sixty lines is written to `notes/<area>.md` in the plan directory by a `general-purpose` child, also on `vm/flash`, which returns only the path, so the plan quotes the path and reads no more of the finding than an item needs.

4. **Grill the real gaps.** Read `~/.agents/skills/grilling/SKILL.md` and put to the owner only what research could not settle and that is theirs to decide, including where tests attach: the highest seam that proves the outcome. A fact is yours to look up, never a question. If nothing is open, say so and skip the round. Ask the frontier in rounds, each question phrased as your recommendation so a bare "yes" accepts it, and use `ask_user_question` only when the whole round is simple picks. Every answer is the owner's: tag it, give it the next `U<n>`, and write it into the plan as settled.
5. **Decompose** by `~/.agents/skills/handoff/SKILL.md` §Decomposition, with these stricter rules for this flow:
   - Write the smallest version first, the one paragraph and the `Not building:` list, then check every item against it. An item the smallest version doesn't need is cut, or it proves the smallest version wrong; say which.
   - Every contract, item and spike justifies itself. A contract with no `Why:` is one to delete, an item whose acceptance doesn't prove its outcome is one to rewrite, and a spike that doesn't buy its timebox is one to drop.
   - `Tier: deep` goes on the few items whose own reasoning is the hard part, not on ones a flash builder can finish by following its item. Write `Tier:` on every item anyway: the approval page rewrites that line.
   - Acceptance is a command a flash builder can run in its worktree and the run lead can re-run on the integration branch. An acceptance nobody has run ends in `(unverified)`, which the page flags.
6. **Write `HANDOFF.md`** to `../../handoff-format.md`, shaped after `handoff-example.md`. That file is the grammar, so follow it instead of working from a template you remember: every required section, every required item field, all five budget bullets, and a `## Stops` that names the owner's gates. `## Context` names each command with its working directory and measured duration, and the skills a builder and its subagents must invoke: a builder that has to guess either one improvises. A file that does not parse refuses approval, and the parser's errors come back to this session as a user message when the owner sends the plan back; fix the lines they name and call `flow_next` again.
7. **Cold read.** Spawn one fresh `Explore` subagent given the plan directory's path, the main checkout's path, and nothing of this conversation. Ask it to read `HANDOFF.md` as a builder would and report:
   - what it could not act on without asking: undefined terms, references to the discussion, items with no runnable acceptance, missing run commands;
   - every in-scope line, every decision of either tier and every contract mapped to the item that delivers it end to end, every review-focus risk and trust boundary mapped to the item whose acceptance covers it, and everything that maps to nothing;
   - the owner actions the decisions imply, and the item that builds each;
   - items that could be in flight together but share `Owns`.

   Fix what it finds. Reopen the grill only for a real decision gap, and run one cold read, not two.

8. **Report and end the step.** One short message in this session: the path, the items with their tiers and blockers, what stayed open, and what you could not verify. Then call `flow_next` with a one-line `note`. The conductor opens the approval page, where the owner edits tiers, mode and settings, answers the open questions and approves, sends back or cancels. Don't wait for that here, don't switch sessions yourself, and don't start the work.

## --quick

`--quick` is the owner's answer to "this is small", and it runs on `planQuick`. It drops the research fan-out and the cold read; nothing else relaxes.

- Check inline what the plan leans on: read the files and interfaces the items touch, find the commands, run the quick ones, and mark the rest `(unverified)` in `## Context`.
- At most three items in a straight line, so no contracts, no gates and no spikes. If the work needs more, say so in one line and write the full plan anyway, with the fuller rules above for whichever parts you can still do; a plan that outgrew quick is worth more written down than suppressed, and the owner can send it back with a note.
- The grammar does not relax. `## Smallest version` with a real `Not building:` list, all five budget bullets and `## Stops` are written even for one item; optional sections with nothing in them are left out.
- Ask one question only where an undecided choice changes what gets built. Everything else goes to `## Open questions`, for the approval page to put to the owner.

## Rules

- `HANDOFF.md` is the plan, and this step is the only one that writes it. The approval page owns the `Tier:` lines afterwards and the run lead owns `## Amendments`; nothing in it is rewritten otherwise.
- `Lines` and `Cost cap` are what stop a run that balloons: `flow_status` measures the branch against them, and the run lead treats going over as a deviation. Estimate both honestly rather than low.
- No secrets, tokens or personal data, and no status in either file. Name where a secret lives.
- Research reads; the plan writes. If you catch yourself building an item, you are past the end of this step.
