---
name: ideate
description: Generate grounded, ranked ideas for improving a repo or one area of it (features, refactors, performance, tooling), each routed to /brainstorm, /grill-me or building it.
disable-model-invocation: true
argument-hint: "[focus] [--quick] [--no-web]"
---

The arguments are a focus (an area, a kind of improvement, or both) plus optional flags. This skill finds ideas worth doing. It designs none of them and writes no code unless the user picks ideas to build at the end.

## Scope

With no focus, ask one question with the harness's question tool (pi `ask_user_question`, Claude `AskUserQuestion`): features, refactors, performance, or "Surprise me" (you go where the evidence points). Ask nothing else; approach and constraints belong to brainstorm and grilling.

Cleanup inventories (disk usage, leftovers, clutter) and topics outside code are out of scope: say so and answer directly, without this workflow.

Classify the ask from the focus: general, features, performance, refactor, tooling/DX, or critique. The kind picks the lenses.

The bar:

- **Default, big swings:** rewrites, removals and new subsystems are fair game. An idea clears the bar if it's worth reorganising a week around.
- **`--quick`:** small changes and deletions. An idea clears the bar if it's worth doing at all.

`--no-web` skips the web generator.

## The file

The topic is `<repo>-ideas-<focus slug>`, or `<repo>-ideas` with no focus. The file is `<dir>/IDEAS.md`, where `<dir>` is `<topic>/` under wherever the user's instructions keep long-lived agent notes, otherwise `.agents/ideas/<topic>/` in the repo. Never commit it. If it already exists, this is a rerun: read it first.

## Ground

Read what the focus touches; sweep the whole repo only with no focus or "Surprise me". Inline for a narrow focus, a fresh subagent for a broad sweep.

- The code, docs and agent instructions in that area.
- Git history: the files that change most (weighted by size), files that change together, recurring `fix:` commits.
- TODO, FIXME and HACK comments.
- Open issues (`gh issue list`), only when the focus asks about them.
- When the subject is tooling the user runs themselves (CLIs, agent harnesses, skills, editor config): their Claude Code transcripts (`~/.claude/projects/`), pi sessions (`~/.pi/agent/sessions/`) and shell history, for friction they actually hit. Read-only.

Write a grounding summary: what's there, the hotspots with paths, and on a rerun the earlier ideas and rejections. Every subagent gets the same summary.

## Generate

Print one line naming the agents you're about to start, e.g. "3 lens generators (hotspots, subtraction, leverage), 1 web generator, then 1 verifier". Then dispatch them in parallel, each a fresh subagent (not a fork) given the grounding summary, the focus, the bar and its own brief. Without a subagent tool, run them one after another inline.

**Lens generators:** three, each from a different row.

| Lens                   | Asks                                                                         |
| ---------------------- | ---------------------------------------------------------------------------- |
| Hotspots               | Where does churn meet size? What changes together? What keeps needing fixes? |
| Subtraction            | What can be deleted, merged or automated? What if this part didn't exist?    |
| Leverage               | What would make many future changes cheaper?                                 |
| Capability reuse       | What already exists here that could solve another problem?                   |
| Gap vs reference       | What does a named or comparable project do that this doesn't?                |
| Pre-mortem             | It's six months later and this got ripped out or broke. Why?                 |
| Measure-first          | What's the biggest number (time, size, cost), and what attacks it?           |
| Constraint provocation | What if load were 10×, the budget zero, or you rewrote it today?             |

Default trios by kind:

- General: hotspots, subtraction, leverage.
- Features: capability reuse, gap vs reference, leverage.
- Performance: measure-first, hotspots, subtraction.
- Refactor: hotspots, subtraction, pre-mortem.
- Tooling/DX: hotspots, subtraction, capability reuse.
- Critique: pre-mortem, subtraction, constraint provocation.

Axes the user names ("for humans and agents", "sorted by tradeoff") replace the lenses: one generator per axis, up to three.

**Web generator:** how peer projects and tools handle the focus area, and what the repo's main dependencies have shipped recently. Each idea cites its source URL and names where it would land in this repo.

Every generator's brief says:

- Aim for 8–10 ideas (4–5 with `--quick`). The first few are the obvious ones; keep them only if they still earn their place once the less obvious ones exist.
- Ideas are free-form, but each has a title and a basis: a `path:line` you read yourself in this run, a source URL, or an argument written out in full. No basis, no idea.
- A performance idea needs a number you measured with something cheap and read-only (time a command, size a closure, profile one run), or else the command that would measure it, marked unmeasured.
- Don't propose anything the summary lists as rejected unless its reason no longer holds.

## Cut

Merge and dedupe. Then give a fresh subagent only the grounding summary, the bar and the merged list, and ask it to refute each idea: is the cited line there and does it say that, does the source exist and say that, does the argument hold, does it clear the bar. It returns sound, weak or refuted, with a reason. You make the final cut, overruling a verdict only with evidence, and say so.

Keep 5–7. If fewer than 5 survive, run one more pass with up to three unused lenses, verify it, and cut again. If still short, report the shortfall rather than lower the bar. When performance is the focus and nothing could be measured, "build the measurement" (a benchmark harness, a timing script) ranks first and the rest are marked unmeasured.

For each survivor decide:

- **Size:** S, M or L.
- **Next:** `/brainstorm` when the approach is still open, `/grill-me` when the approach is clear but holds decisions, build when it's straightforward.
- **Needs:** other survivors it depends on. Otherwise it must stand alone.

Rank by payoff per effort.

## Write

Write `IDEAS.md`. On a rerun, edit it in place: re-check carried-over ideas against the current code and keep the rejections.

```markdown
# Ideas: <focus>

<date> · <bar> · Looked at: <areas, history window, other sources>

## Ideas

### 1. <title>

<What, in 1–3 sentences.>

- Basis: <path:line and quote, URL, or argument>
- Why: <the payoff>
- Size: S · Next: /grill-me · Needs: none
- Status: <blank, or picked and where it went>

## Rejected

- <title>: <one-line reason>
```

In chat, show only the path, the counts ("7 ideas from 34 candidates"), one line per idea (`1. <title> · <size> · <next>`) and the top pick in a sentence.

## Pick

The user replies by number or in free text:

- **Merge, refine or question:** answer, and update the file when an idea's content changes.
- **Build** ("do 1, 3", "fix 2"): if a picked idea's next step is `/brainstorm` or `/grill-me`, ask once whether to build it anyway or route it first. Then build them in this session one at a time, run the repo's checks, and mark each one done in `IDEAS.md`.
- **Any other pick:** restate the idea as a seed (what, basis, why) and name its next command. Mark it picked in the file.
