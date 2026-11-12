# skills

Agent skills used in my Claude Code setup, kept here so they're installable in any
repo with [`npx skills`](https://github.com/vercel-labs/skills). On my own machines
home-manager symlinks this same directory into `~/.claude/skills`, so it's the single
source: published and deployed from one place.

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

### Plan, build and ship

- [handoff](handoff/): turns a finished brainstorm into a self-contained plan for another agent, with vertical-slice work items that carry owned paths and acceptance commands; `--quick` writes a short one inline with no subagents, asking only what's still open.
- [run-handoff](run-handoff/): builds a handoff in one long-running session, one subagent and worktree per item, each re-verified before it lands on an integration branch; checks in at gates unless run with `--auto`.
- [land](land/): takes finished work to landed commits or a PR, after the repo's checks and a review gate: from a worktree, from a branch in the primary checkout, or by pushing commits made on its default branch; needs worktrunk (`wt`) for local landing, and `gh` for the PR endings.

### Understand and decide

- [onboard](onboard/): teaches you an unfamiliar project by running it in a throwaway clone and tracing one real action, then saves an overview with its core features, architecture and evidence-labelled design choices, plus a trace guide, a quiz and offered dives into subsystems; `--quick` answers from static analysis in chat.
- [compare](compare/): recommends one of a field of candidates after a one-round brief, gated per-candidate research and a refuting verifier, with the verdict in chat; `--quick` answers inline.

### Clean up

- [prune-comments](prune-comments/): cuts redundant, over-long or coupled comments and docstrings (file/line references, caller lists, change narration) down to the load-bearing why; run it after generating code.
- [prune-churn](prune-churn/): removes tests, docs and structure that must be edited whenever something else changes, ranking churn hotspots from git history.

### Harnesses

Run the real thing and drive it by observation: keys, pointer, screenshots and logs.

- [pi-plugin-dev](pi-plugin-dev/): builds and debugs pi extensions by observation, with tmux-driven TUI sessions, screenshots, session digests and a replay provider.
- [claude-mod-dev](claude-mod-dev/): runs a Claude Code mod in a real session in tmux and drives it with keys, captures at several widths, screenshots and the engine's debug log, with the engine limits that tests don't show.
- [dms-plugin-dev](dms-plugin-dev/): runs a DankMaterialShell plugin in real DMS inside an isolated headless sway, and drives it with keys, a pointer, screenshots and its QML log

### Utilities

- [mermaid](mermaid/): renders the Mermaid diagrams in a markdown file to SVGs linked above each block, with a vendored renderer; used by `onboard` and `tour`; needs Node.
- [pricerunner](pricerunner/): searches, filters and compares Danish prices on PriceRunner.dk through its unofficial frontend API, including shop offers, price history and deals.

## Modified public skills

My variants of skills published elsewhere. Install the originals from their source unless you want my changes specifically.

- [grilling](grilling/): interviews you about a plan in rounds, asking every decision whose prerequisites are settled, each with a recommended answer; other skills call it.
- [grill-me](grill-me/): the `/grill-me` entry point to `grilling`, for sharpening a plan before you commit to it.

Both are reworked from the latest version of [Matt Pocock's `grill-me`](https://github.com/mattpocock/skills).

- [avoid-ai-tropes](avoid-ai-tropes/): checks human-facing prose against a catalog of AI writing tells and rewrites what matches; run it by name.

Its catalog comes from [tropes.fyi](https://tropes.fyi) by [ossama.is](https://ossama.is).

## In progress

Unfinished and not recommended yet: their shape and behaviour will change. Each carries `status: in-progress` in its frontmatter `metadata`.

- [brainstorm](brainstorm/): finds an approach for a goal that has none yet, offering 2–3 different ones after a round or two of questions, and stops once you pick.
- [ideate](ideate/): ranked improvement ideas for a repo or one area of it, refuted by a fresh verifier, each routed to `/brainstorm`, `/grill-me` or building it.
- [tour](tour/): walks you through a pull request or a stack of them one PR at a time, with a one-screen map per PR (intent, decisions to judge, reading order, what to skip, with mechanical files marked viewed on GitHub), then stays to answer questions; it never reviews or comments; needs `gh`.
- [retro](retro/): improves how agents work from one session: a fresh reviewer finds the detours and mistakes and what caused them, quality first, then time, then cost, and the fixes you pick get applied; needs `python3`.
- [mine](mine/): improves a skill, tool, CLI or hook from how its runs went in past Claude Code and pi sessions.
- [windows-vm](windows-vm/): operates a libvirt Windows guest from the host, starting and stopping it without corrupting NTFS and driving it with screenshots, keys, clicks and PowerShell through the QEMU guest agent.
