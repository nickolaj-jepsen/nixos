# skills

Agent skills used in my Claude Code setup, kept here so they're installable in any
repo with [`npx skills`](https://github.com/vercel-labs/skills). On my own machines
home-manager symlinks this same directory into `~/.claude/skills`, so this is the
single source — published and deployed from one place.

## Install

All of them:

```bash
npx skills add nickolaj-jepsen/nixos
```

Or pick one by its subpath:

```bash
npx skills add https://github.com/nickolaj-jepsen/nixos/tree/main/skills/grill-me
```

Or as a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`):

```bash
claude plugin marketplace add nickolaj-jepsen/nixos
claude plugin install skills@nickolaj-jepsen
```

## What's here

- **grilling** — the interview primitive: questions a plan in rounds, each round every
  decision whose prerequisites are settled, with a recommended answer per question.
  Looks facts up itself and stops at a confirmation gate. Other skills invoke it.
- **grill-me** — the `/grill-me` entry point to `grilling`. Good before committing to an
  approach.
- **grill-me-legacy** — the original grill-me, one question at a time.
- **ideate** — ranked improvement ideas for a repo or one area of it: lens-driven
  subagents plus a web scout generate, a fresh verifier refutes, 5–7 survive into an
  `IDEAS.md`, each routed to brainstorm, grill-me or building it.
- **mine** — improve a skill, tool, CLI or hook from how it actually went in past Claude
  Code and pi sessions: a bundled reader finds every run and its signals (answers,
  interrupts, denials), runs are read for first failures, you confirm the categories, and
  routed findings land in a `FINDINGS.md`. With no target, a retro of the current session.
- **brainstorm** — find an approach when there isn't one yet: a round or two of
  clarifying questions, then 2–3 genuinely different approaches to pick from. Stops
  once you pick.
- **compare** — recommend one of a field of candidates: a one-round brief settles
  purpose and must-haves, must-haves gate the field, one isolated researcher per
  finalist, and a verifier refutes every cell before a compact verdict in chat.
  `--quick` answers inline.
- **annotate-plan** — the agent writes a `PLAN.md`, you annotate it in your editor, and
  it folds your notes in round after round until you approve; then it implements on
  request, ticking progress off in the file. For changes too big to just start and too
  small for a handoff.
- **prune-comments** — strip redundant, over-long or coupled comments and docstrings
  (file/line references, caller lists, change narration) down to the load-bearing
  why. Run it after generating code.
- **prune-hard** — the harsh sibling: deletes by default and keeps only the traps,
  for private code where the reader is you and git history.
- **prune-churn** — remove tests, docs and structure that must be edited
  whenever something else changes: mock-echo tests, broad snapshots, inventory docs,
  hand-synced registries. Ranks churn hotspots from git history.
- **avoid-ai-tropes** — catalog of AI writing tells to check human-facing prose
  against and rewrite. Sourced from [tropes.fyi](https://tropes.fyi) by
  [ossama.is](https://ossama.is); credited in the skill file.
- **pricerunner** — search, filter and compare Danish prices on PriceRunner.dk via its
  unofficial frontend API: facet filters, categories, offers, price history, deals.
- **windows-vm** — operate a libvirt Windows guest from the host: find it and its disks,
  start and stop it without corrupting NTFS, screenshots, keys and clicks, and PowerShell
  through the QEMU guest agent.
- **pi-plugin-dev** — build and debug pi extensions by observation: tmux-driven TUI
  sessions, color screenshots, session digests that replay the prompt and tool
  loadout, and a replay provider so tool and error paths run without a model.
- **memory-sync** — sync one repo's memories both ways between pi's memory store and
  Claude Code's auto-memory: adds and updates proposed for one approval, never deletes.
  Runs in pi.
- **wt-land** — take finished work in a git worktree to landed commits: shape it into a
  few, run the repo's checks, stop at a review gate, then land with `wt land` or open a
  PR (draft, awaiting review, or merged on green). Needs `wt`, `gh` and `python3`; the PR
  half lives in a bundled `scripts/pr.py`.
- **wt-promote** — move a worktree's branch into the repo's primary checkout for work that
  has to run from that path. Whatever sits there goes to its own worktree: the agent working
  there is asked to move it, or the skill moves it. It offers a rebase onto local or origin
  main first; `--back` hands the path back. Needs `wt`'s `promote`/`evict` verbs.
- **handoff** — turn a finished brainstorm into a self-contained plan for another agent:
  pin the scope, verify assumptions with read-only subagents, grill only the open
  decisions, agree the item graph, then write vertical-slice work items with owned paths
  and acceptance commands.
- **run-handoff** — build a handoff in one long-running session: every unblocked item
  goes to a subagent in its own worktree, re-verified by the lead before it lands on an
  integration branch, with reviews at gates and over the whole branch. Checks in at gates
  by default; `--auto` runs unattended.
