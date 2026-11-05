# /flow

Read this before changing `modules/programs/pi/extensions/parent/flow/`
(written `E/parent/flow/` below), the flow skills in `E/parent/flow/skills/`, the
`builder`, `builder-deep` or `reviewer-deep` roles, or the `/flow` command.
`docs/models.md` covers the models the steps and roles use.

## What it is for

A long task is expensive when one session grows and a strong model has to keep
re-reading it. `/flow` splits the task into steps that each run in a new session
linked to the last, so a model only ever reads a short, distilled input: the
brief for the plan, the plan for the run. Most of the work then happens on cheap
models, and a strong model is spent only where its reasoning changes the
outcome.

It also fixes what a run tends to get wrong on its own. A code-rendered approval
page comes before any work starts, so the owner can see what will be built and
where the run may stop. The run has a budget, a written deviation rule and a
stop mode. It ends with a simplify pass and a review guide, because a branch
built by several agents is hard to read without a reading order.

`/flow` is pi-only. Skills live in the parent package, so a Claude Code port
would have to bring its own prompts.

## The five steps

| Step      | Session                  | What happens                                                            |
| --------- | ------------------------ | ----------------------------------------------------------------------- |
| `brief`   | the one you started in   | `flow-brief` writes `BRIEF.md` from the conversation and its decisions. |
| `plan`    | new, linked              | `flow-plan` turns the brief into `HANDOFF.md`, grilling only real gaps. |
| `approve` | none; an overlay in plan | The approval page shows the plan and takes the owner's edits.           |
| `run`     | new, linked              | `flow-run` builds the approved plan, gate by gate, and simplifies it.   |
| `guide`   | new, linked              | `flow-guide` writes `REVIEW-GUIDE.md` and seeds the tuicr tour.         |

`done` is a state, not a session: the flow's last step clears the footer and
leaves the plan directory for the owner.

The brief keeps the model the starting session already runs on; that model holds
the conversation and is the only one that can write the brief from it. Every
later step's model and thinking level come from the settings table. The step
table, the kickoffs and the settings live once in `E/parent/flow/contracts.ts`;
read it rather than a summary here.

A skill ends by calling the `flow_next` tool. The conductor records the step's
end and cost, writes `FLOW.json`, and only then creates the next session. The
`/flow next` a tool call asks for is sent after the turn settles, because a
session switch in the middle of a turn leaves an aborted message behind. Where a
step needs the owner's word first, `flow_next` opens that question:

- brief → plan always shows a picker with the judge's suggestion, the other plan
  stage and an edit path;
- plan → approve opens the approval page, after parsing the handoff;
- run → guide confirms only in `gated` mode.

## Commands

- `/flow <slug>` starts a flow in this session and sends the brief skill at it.
  The slug names the plan directory and the integration branch. Without a slug,
  pi asks for one.
- `/flow` shows the status: steps and their sessions, models, spend per step,
  mode, budget, and PROGRESS.md's "Blocked on you" section when it has one.
- `/flow resume [slug]` reopens the recorded session of the current step, or
  retries a step whose session was never created.
- `/flow next` advances. A bare `/flow` or a finished flow says so instead.

There is no `/flow amend`. A change the owner wants mid-run is told to the run
lead, which records it under `## Amendments` in `HANDOFF.md`. The run lead never
rewrites the plan otherwise.

## State

The plan directory is
`~/.local/share/agents/<project>/plans/<slug>/`, where `<project>` is the main
checkout's directory name. It holds `BRIEF.md`, `HANDOFF.md`, `APPROVAL.md`,
`PROGRESS.md`, `REVIEW-GUIDE.md` and `FLOW.json`.

`FLOW.json` is the only state that crosses a session switch: the current step,
mode, plan stage, settings overrides, each step's session file and cost, the
judge's verdicts, and the tour. `flow/state.ts` owns every read and write of it, and writes are atomic.
The format is C1 in the build's own plan; the parser is `parseFlow` in
`contracts.ts`. A file that does not parse is reported and left as it is.

## Modes

Chosen on the approval page, with the judge's suggestion preselected:

- `gated` stops at every gate and on every deviation.
- `deviation` self-checks ordinary gates and stops only on a deviation.
- `straight` logs deviations and continues to the final report.

A mode governs gates and deviations; the plan's explicit `## Stops` and
`flow-run`'s safety stops apply in every mode.

The deviation list, the budget rule and the safety stops are written once, in
`flow-run`'s skill. In outline: an overturned Default that changes behaviour, a
contract or the budget; a Yours decision proven wrong; scope or contract drift;
a materially simpler approach; a blocked item; spend or diff lines over the cap.

## Settings and the judge

Settings are keyed by step and by role: `judge`, `plan`, `planQuick`, `run`,
`guide`, `items` (role and deep role), `gateReview`, `finalReview`, `simplify`.
The defaults are in `contracts.ts`. A host may override them through the pi
leaf's `flow` setting; `FLOW.json.settings` overrides both for one flow. An
invalid value falls back to the layer below and is reported, never thrown.

The pi leaf ships no `flow` key on purpose: the wrapper deep-merges the leaf's
settings into every agent dir at launch, including a scenario's scratch dir, so
a table there would overwrite the scenario's fixture models.

A flash judge reads `BRIEF.md` at brief → plan and the parsed handoff before the
approval page. It suggests the plan stage and model, the run's model, the mode,
per-item tiers and the final reviewer, each with a one-line reason. Both
verdicts and their costs are stored in `FLOW.json` beside the step costs. When
the call fails, the defaults stand and the failure is the reason.

## Tiers and roles

The planner marks items `Tier: flash` or `Tier: deep`; the judge may suggest
tiers and the owner can change any of them on the approval page. A step names a
role, never a model:

- `builder` for a flash item, `builder-deep` for a deep one. Both lock only the
  model, so the item's thinking level applies.
- `reviewer` for an ordinary gate; `reviewer-deep` for the final gate, where it
  also names what could be deleted or merged. The reviewer roles lock their
  thinking level.

One hard item can be deep without moving the whole run.

## The approval page

`E/parent/flow/approval.ts` renders the plan as a scrolling TUI overlay and
writes the same content to `APPROVAL.md`. It shows the mission, the smallest
version and its not-building list, the item graph with blockers, the files each
item owns, gates, stops and the budget, and flags every acceptance marked
`(unverified)`.

Editable on the page: the mode, the run step's model and thinking level, each
item's tier, and answers to open questions. Answers are appended under
`## Amendments`, dated and marked as the owner's. Approving starts the run;
sending back returns the note to the plan session; cancelling leaves the flow at
its plan step. Outside the TUI it writes `APPROVAL.md` and asks with
`ctx.ui.select`.

## The handoff

`HANDOFF.md` is the plan the run reads. Its grammar is
`E/parent/flow/handoff-format.md`, with `handoff-example.md` beside it as a
complete file the parser accepts. The parser is `parseHandoff` in
`handoff.ts`; approval is refused when the file does not parse and the errors go
back to the planner as a user message.

A plan has a mission, a smallest version with its not-building list, scope,
context, locked decisions in two tiers, work items, a budget and stops. Optional
sections cover contracts, trust boundaries, review focus, project rules and open
questions.

## Budget

Two axes, both from the handoff: spend in dollars and diff lines against the
base. `flow_status` reports each, with the line cap being the handoff's `Lines`
times 1.5. Going over either is a deviation, so it stops a gated or deviation
run and is logged in straight mode.

Step costs are computed from the session's usage breakdown when the step ends,
because the old session cannot be read after the switch. Subagent spend lags a
child that is still running, so a budget check right after dispatching is early.

## The guide and the tour

`flow-guide` writes `REVIEW-GUIDE.md` in the plan directory from the plan, the
progress file and the branch diff: reading order, core versus mechanical areas,
where to look hard, what was verified and how, the calls the build made, and any
simplification deferred to the owner.

It also seeds a tuicr tour through `flow_tour`. The tool opens the session
headlessly from the main checkout on `-r <merge-base>..<branch>`, checks every
stop's line against the diff, adds the stops as the author `Flow`, and records
the slug, argv and `/rv` line in `FLOW.json`. The guide prints that exact `/rv`
line, because a tuicr session is tied to its argv, its checkout and its branch.

`/rv`'s ingest drops comments authored `Flow`, so a later `/rv send` carries the
owner's comments and not the tour's. The tour stays visible in tuicr itself.

## Traps worth knowing

- pi 1.5.0 has no `setModel` or `setThinkingLevel` on the session handed to
  `withSession`, and the captured `pi` is stale after a switch. A step's model is
  applied in the new instance's `session_start` with reason `"new"`. `setModel`
  returns `false` without throwing when a provider has no auth.
- A throw inside `withSession` exits pi. The whole body is wrapped.
- A session switch aborts running subagents, so `flow_next` refuses while one is
  still running.
- `ctx.ui.custom` returns `undefined` in RPC mode, so the approval page has a
  non-TUI path.
- Skills ship from the parent package's `pi` manifest, which is all-or-nothing:
  listing `extensions` there also needs the `skills` entry.
- Subagent children get the package's skills too, so the flow skills are
  `disable-model-invocation: true` and must work when the flow tools are absent.
- Don't rename a skill to `flow`: the alias rewrite would hijack the command.

## Tests

Unit tests are `parent/flow/*.test.ts` and run with `npm test` from
`modules/programs/pi/extensions/`. The shell scenarios in
`E/parent/flow/scenario/` drive a real pi on a replay provider, so they cost
nothing and assert on what the pane would show:

- `e2e.sh` is the walking skeleton: brief to done through the picker, the
  approval page and the gated gate, with the tour seeded.
- `transitions.sh` proves the session chain, each step's model and level, costs
  and resume behaviour.
- `approval.sh` drives the page's edits and a send-back.
- `tour.sh` checks the tour's argv, author filter and a real tuicr render.

Like the review scenarios they are not part of `just check`; run the one you
touched.
