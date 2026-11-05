---
name: flow-run
description: Build a flow's approved plan in one session. Dispatch items by tier, apply the mode's deviation and budget rules, and finish with the final gate and simplify pass.
disable-model-invocation: true
argument-hint: "<plan-dir>"
---

# flow-run

You are the run lead and integrator. Execute the approved plan; do not redesign it.

- `HANDOFF.md` is the plan. It is read-only except for owner changes appended under `## Amendments`.
- `PROGRESS.md` is yours. Keep it accurate enough to resume after a crash or context reset.
- Call `flow_status()` for the slug, plan directory, main checkout, base and branch, mode, resolved settings, roles and budget. Never read `FLOW.json` yourself.
- The plan-directory argument must match `flow_status().planDir`. Use the absolute paths it returns. If its mode is absent, treat the run as `gated`.
- This skill belongs in the flow's run session. If `flow_status` or `flow_next` is unavailable, do not run the plan, read `FLOW.json` or substitute `/flow next`. In a subagent child, return to the item you were assigned and report the missing tool to the lead; with no assigned item, stop and explain.

## Worktrees

Running the plan requires an integration worktree and a separate worktree for each item. Never build in the main checkout.

Use the owner's worktree tool (`wt new`, then `wt close` after integration) when available, otherwise `git worktree add` and `git worktree remove`. Worktrees live under `~/worktrees/<repo>/`. The integration branch and item branch names come from the flow slug and item ID.

Pi subagent children have no `cwd` parameter, and each bash call starts back in the parent's checkout. Every item brief must therefore give absolute paths and require `git -C <worktree>` for git commands. For a command without a `-C` option, prefix that invocation with `cd <worktree> &&`; never assume a previous `cd` persisted. Do not propose a WorkspaceProvider.

## Modes

Read the mode from `flow_status`; it is not a command-line option.

- `gated`: stop for the owner at every gate and on every deviation.
- `deviation`: self-check ordinary gates, but stop on a deviation.
- `straight`: log deviations and continue to the final report without stopping for them.

A mode governs gates and deviations; the plan's explicit `## Stops` and the safety stops below apply in every mode. In `straight`, a blocked item remains blocked: continue other work and report it rather than inventing a way around the plan.

## Decisions and owner changes

HANDOFF's Yours decisions lock. A Default may change when evidence shows it is wrong; whoever changes it must state that evidence. Amendments override earlier text. In a HANDOFF without decision tiers, treat every locked decision as Yours.

When the owner answers a question or changes the plan mid-run, append one bullet under `## Amendments`:

`- <YYYY-MM-DD>, owner: <what the owner settled>`

Append only the owner's word, never your own proposal or judgment. Update `PROGRESS.md`, stop dispatching affected items, and reconcile work already in flight with the change. Use `steer_subagent` for a running child that must change course, or resume it with new instructions after it reports. There is no separate amend command.

## Start or resume

1. Call `flow_status()` and read `<planDir>/HANDOFF.md` in full, including Amendments, Stops and Stop conditions. Read cited notes only when an item needs them.
2. If `PROGRESS.md` exists, resume:
   - Reconcile it with the integration branch, item worktrees and commits. Where they disagree, git wins; correct `PROGRESS.md`.
   - Run the standard checks on the integration branch before dispatching anything. Repair a crashed integration first.
   - Put only Open questions with no Amendment answering them in `Blocked on you` and continue from `Now`.
3. On a first run:
   - Create the integration worktree on `<branch>` from `<base>`. With `wt`, `wt new <slug> <base>` prints its path.
   - Create `PROGRESS.md` from the template below, carrying only Open questions with no Amendment answering them into `Blocked on you`.
   - Run Context's build and test commands once on the integration branch and record their durations.
   - Do bootstrap items and `G0` yourself when the plan has them.

## Deviations and budget

A deviation is any of:

- an overturned Default that changes observable behaviour, a contract, another item's `Owns`, or the budget;
- a Yours decision proven wrong;
- an item proposing a change to scope or a contract;
- a reviewer finding a materially simpler approach;
- a blocked item;
- `spentTotal` over `costCap`, or `lines` over `linesCap`.

The lead decides which case applies. Any other overturned Default needs no owner prompt: record its evidence under `### Calls the build made` in `PROGRESS.md` and continue.

Check budget through fresh `flow_status()` calls after children finish, after integrations, before gates and before the final report. `linesCap` already includes the handoff's 1.5 allowance. A cap of 0 means that axis is uncapped. The budget numbers can lag a running child, so judge cost again after joining it.

In `gated` and `deviation`, a deviation stops the affected path. Record the evidence and a proposed resolution in `Blocked on you`, ask the owner, and let unrelated in-flight items finish. Do not integrate work that depends on the unresolved decision. An approved plan change also goes under Amendments.

In `straight`, record the deviation and the chosen course under `### Calls the build made`, then continue. Include the actual and cap values for a budget breach.

## Item loop

1. Find the frontier: every item whose blockers are done, or integrated with only device or person acceptance open, and whose `Owns` does not overlap an item in flight. Break otherwise equal ordering by item ID.
2. Dispatch up to HANDOFF's concurrency cap, defaulting to 3. For each item:
   - Create `<slug>-<id>` from the integration branch's current head and keep its absolute worktree path.
   - Read its `Tier:` line. Use `settings.items.role` for `flash` and `settings.items.deep` for `deep`.
   - Call `subagent` with that role, `run_in_background: true`, `settings.items.thinking`, and the item brief below.
3. While items run, do gate work or wait for completion notices. Do not poll. Join each result with `get_subagent_result`.
4. Route the report by its status line:
   - `DONE`: integrate it.
   - `DONE_WITH_CONCERNS`: read the concerns, then integrate or send back. Log your call.
   - `NEEDS_CONTEXT`: answer from HANDOFF or its notes, then continue the same child with `subagent` and `resume: "<agent id>"`. If only the owner can answer, treat the item as blocked.
   - `BLOCKED`: mark it blocked with the reason and apply the deviation rule.
5. Check every reported Default change against its evidence before integrating. Apply the deviation rule, or log it under `### Calls the build made` when no prompt is needed.
6. Integrate:
   - Confirm the item branch is based on the integration branch's current tip. If the tip moved, resume the child for a rebase, or do a trivial rebase yourself.
   - On the item tree, re-run its acceptance yourself, plus the repo's standard checks and any walking skeleton. Never take the child's word for a pass.
   - If all pass, fast-forward the integration branch. Record the commands, results and commit. Read the item's report, then delete `.handoff-report.md` and every untracked artefact the item left, including `.flow-logs/` and other logs its report names. Confirm `git status --porcelain` is empty before closing the worktree.
   - If anything fails, send the output to the same child and resume it. After two send-backs, mark the item blocked with the last failure.
   - If only device or person acceptance remains open, integrate now and record that acceptance as open. Its dependents may run. Complete the open step when possible and put any fix on top.
7. Re-check the frontier after every integration. Update `PROGRESS.md` after every item and before any long operation.

Run long commands in the background with a deadline and output files. Grep the files for failures instead of reading whole logs.

## Item brief

Each item child's prompt contains:

- Role: build one item. The lead owns `PROGRESS.md`, integration, contracts and gate reviews.
- Where: the absolute worktree path. Work and commit only there, in small commits matching the repo's style. Every bash call starts in the parent's checkout; use absolute paths, `git -C <worktree>`, and a per-command `cd` where needed.
- What: its item ID. Have it read `HANDOFF.md` itself, including Context and its Skills line, Locked decisions, Contracts, Rules, Gotchas, its item and cited notes. Do not paraphrase the plan.
- Boundaries: change only its `Owns`; name paths owned by items in flight as off limits. Never edit contracts, `HANDOFF.md` or `PROGRESS.md`. No push and no external services beyond what HANDOFF allows. A Default may change only with evidence stated in the report.
- Blocked decisions: if a contract or Yours decision blocks the item, finish what it can and report the proposed change instead of working around it.
- Flow tools: children cannot call `flow_next`. Parent-shipped skills may still be visible, but an absent flow tool is expected. Do not call `/flow next` or read `FLOW.json`; finish the item and report to the lead.
- Done: rebase onto the integration branch's current tip, then run the item's acceptance there and report its output.
- Report: write an untracked `.handoff-report.md` in the item worktree. Its first line is exactly `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT` or `BLOCKED`. Then give branch and worktree, commits, acceptance commands and results, decisions and why, contradictions with HANDOFF, and measured timings. State failures and skips plainly. Keep logs in files and give their paths. The child's final message is only its status line and the report path.

## Gates

A gate passes when its items pass acceptance on the integration branch and a fresh reviewer signs off. Fix confirmed findings before passing it, and record the gate commit and verdict.

For an ordinary gate, call `subagent` with `settings.gateReview.role`, read-only instructions and `run_in_background: true`. The reviewer role locks its thinking level, so do not pass one. Join it with `get_subagent_result`.

Give the reviewer:

- the diff since the previous gate, or since the base for the final gate;
- the absolute `HANDOFF.md` path and the gate's item IDs;
- no builder reports.

Ask for defects, contract violations, scope drift, uncovered review-focus risks, acceptance checks that do not prove their outcome, and decisions or owner actions with no reachable path. Above about 3k changed lines, split the review by area among fresh reviewers.

If HANDOFF has Trust boundaries, the first gate after an item touches one and the final gate also get a security reviewer. Give it only the boundaries and diff, and ask for a path by which untrusted input reaches a secret or crosses a boundary.

After a gate in `gated`, present the gate, acceptance results, reviewer verdict, surprises and newly opened frontier. Ask go or adjust with `ask_user_question`, or a numbered list if the question does not fit that tool. In the other modes, record the result and continue unless a deviation or explicit stop applies.

## Final gate and simplify

The final gate reviews the whole integration branch against the merge base of `<base>` and `<branch>`. It cannot pass while any device or person acceptance is open.

1. Run a fresh, read-only reviewer with `settings.finalReview.role`, `settings.finalReview.thinking` and `run_in_background: true`. In addition to the ordinary review questions, require a "could be deleted or merged" list. For each suggestion, ask what it removes, why it is safe and roughly how much of the branch diff it touches.
2. Fix confirmed defects in one pass and re-run the affected checks. Then classify the simplification suggestions:
   - Mechanical: dead code, single-use abstractions, comments and duplicated helpers. Apply all of them with `settings.simplify.role` and `settings.simplify.thinking`. Run this as an item-like change in its own worktree and integrate it only after its checks pass.
   - Structural: behaviour, a public interface, an item's outcome, or a change over about 15% of the branch diff. In `gated`, ask about all structural suggestions in one round. In `deviation`, handle them as a deviation. In `straight`, defer them to the guide. Apply approved structural suggestions with `settings.simplify.role` and `settings.simplify.thinking`.
3. Record rejected or deferred structural suggestions under `## Deferred simplifications` in `PROGRESS.md`, with the reason and size estimate. If the owner approves one that changes the plan, append the owner's decision under Amendments before building it.
4. After simplification, run a fresh reviewer with `settings.gateReview.role` on only the simplify diff. Fix confirmed findings and repeat that focused review until clean.
5. Re-run every item's acceptance and the repo's standard checks on the final integration tree. Record the results and final gate verdict. Refresh `flow_status()` for final cost and diff size.

## Stop conditions

HANDOFF's `## Stops` and `## Stop conditions` are part of the run's stop list. Every mode also stops when:

- incomplete items remain but none is unblocked;
- the next step would push, land, open a PR, call an external service HANDOFF does not allow, or delete work the run did not create;
- continuing safely requires information only the owner has.

Never edit HANDOFF to get unstuck. Put the evidence and proposed change in `PROGRESS.md`; only the owner's word makes it an amendment. When blocked in a non-gated mode, add the request to `Blocked on you` and continue unrelated unblocked work where the deviation rules permit it.

## PROGRESS.md

```markdown
# Progress: <slug>

## Now

<In flight, next up.>

## Items

| ID | Status | Worktree | Send-backs | Acceptance result | Commit |

## Gates

| ID | Commit | Reviewer verdict |

## Blocked on you

<Dated, with an ID (Q1...): what is needed, what it blocks, what continues meanwhile, and the answer once given. Open questions, owner decisions and proposed amendments go here.>

## Decision log

<Dated gate, integration and deviation decisions, with evidence.>

### Calls the build made

<Every non-deviation Default change and every call made while continuing in straight mode. Include evidence and actual versus cap values where relevant. flow-guide reads this heading.>

## Surprises and failed approaches

## Measurements

## Deferred simplifications

<Structural suggestions left for the guide, with reasons and size estimates.>

## Handoff retro

<At run end: what HANDOFF got wrong, omitted or over-specified, and which decisions or gotchas the build had to discover.>
```

## Final report and advance

1. Join every child with `get_subagent_result`. No builder or reviewer may still be running when the run step ends.
2. Write the handoff retro. Report what is done and verified, acceptance results, blocks, failures and skips, measured timings, final budget readings, deferred simplifications, the integration branch and any worktrees left.
3. Ask in one round every unanswered `Blocked on you` entry the owner can answer now, with your recommended answer and what continued meanwhile. This applies in every mode because the run is over. Use `ask_user_question` where it fits, otherwise a numbered list. Record answers and complete any work they call for before advancing.
4. Landing is the owner's call. Whenever it comes up, name what remains unanswered first. Do not delete the plan directory; the guide step still needs it.
5. Call `flow_status()` once more, then confirm no subagents are running. Call `flow_next({note: <short run summary>})` and end your turn. The conductor handles the `run -> guide` confirmation for `gated` mode. If `flow_next` refuses because a child is still running, join that child and retry only after none remain. Never issue `/flow next` yourself.
