---
name: ideate
description: Find what is worth doing with a repo, one area of it or a tool, and show the evidence for it. Gives ranked ideas for an open question, approaches for a design problem, or a sourced answer for a research question.
disable-model-invocation: true
argument-hint: "<area, question or problem> [--big|--quick] [--no-web]"
metadata:
  status: in-progress
---

The user has an open question about what to do with something: where a repo could improve, what to build with a technology, how to redesign a part that grew unwieldy, whether a tool or workflow exists for a problem. Find out what's worth doing and show the evidence for it. Nothing is built until the user picks.

- The arguments are the ask, in the user's words. Say in a line what you take it to be and what you'll look at, then go. Don't bend it into one shape:
  - A focus or "what could we improve here?" gets ranked ideas.
  - A design problem ("redesign X, it's unwieldy") gets what the problem really is, then a few approaches with their trade-offs.
  - A research question ("is there a tool that helps with Y?") gets an answer with sources.
  - A list of frustrations gets the causes behind them and what would remove them.
- With no arguments, ask what to look at.
- A cleanup inventory (disk usage, leftovers) or a topic outside code needs none of this, so answer it directly.

## Bar and flags

An idea is worth including if it's worth doing at all, from a one-line deletion to a rewrite. What keeps the list from being generic advice is that every idea has a basis:

- A `path:line` you read in this run, a source URL, or an argument written out in full.
- For performance, a number you measured cheaply (time a command, size a closure, profile one run), or the command that would measure it, marked unmeasured. When nothing could be measured, building the measurement ranks first.

Flags:

- `--big` keeps only swings worth reorganising a week around: rewrites, removals, new subsystems.
- `--quick` keeps only S-sized changes and deletions.
- `--no-web` skips looking outside the repo.

If fewer ideas survive than you hoped, report the shortfall rather than lower the bar.

## Where to look

Read what the ask touches, and sweep the whole repo only when it names no area.

- The code, docs and agent instructions in that area.
- Git history: the files that change most for their size, files that change together, recurring `fix:` commits.
- TODO, FIXME and HACK comments, and open issues when the ask is about them.
- Peer projects and what the main dependencies shipped recently, unless `--no-web`.
- For tooling the user runs themselves (CLIs, agent harnesses, skills, editor config): their Claude Code transcripts (`~/.claude/projects/`), pi sessions (`~/.pi/agent/sessions/`) and shell history, read-only, for friction they hit. `/mine` reads transcripts properly when that is the main question.

Lenses are prompts for finding ideas. Pick the ones the ask calls for:

| Lens                   | Asks                                                                         |
| ---------------------- | ---------------------------------------------------------------------------- |
| Hotspots               | Where does churn meet size? What changes together? What keeps needing fixes? |
| Subtraction            | What can be deleted, merged or automated? What if this part didn't exist?    |
| Leverage               | What would make many future changes cheaper?                                 |
| Capability reuse       | What already exists here that could solve another problem?                   |
| Gap vs reference       | What does a named or comparable project do that this doesn't?                |
| Pre-mortem             | It's six months later and this got ripped out or broke. Why?                 |
| Measure-first          | What's the biggest number (time, size, cost), and what attacks it?           |
| Constraint provocation | What if load were 10x, the budget zero, or you rewrote it today?             |

## Scaling the work

A narrow ask is read and answered inline. A wide "find me ideas" sweep is where parallel work pays off: a few generators, each on a different lens or on the web, and then a verifier that tries to refute the merged list (is the cited line there and does it say that, does the source exist, does the argument hold, does it clear the bar). Ask each for more than you'll keep, since the first ideas are the obvious ones. Overrule a verifier only with evidence, and say so.

A subagent is a fresh one, not a fork: a fork inherits your framing and tends to agree with it. Its brief carries the grounding you gathered, the ask, the bar and the privacy rules, and names transcripts by session id instead of pasting their text. Without a subagent tool, do the same work inline.

## Reply

Answer the ask in whatever shape fits it. For a question or a design problem that is prose, with sources, and no list is needed.

When the reply is a set of ideas to pick from, rank them by payoff per effort and end with a numbered list, one line per idea: `N. <title> · <S|M|L> · <build|/grill-me|/brainstorm>`. The route is `/brainstorm` when the approach is still open, `/grill-me` when it's clear but holds decisions, and build when it's straightforward. Keep the route last on the line and put each idea's payoff in the prose above the list: the `answer` plugin turns a reply that ends in such a list into a form to pick from, and it reads the route off the end of each item. Mention dependencies between ideas, anything rejected that the user might expect, and which one to start with.

After the reply, do what the user says: build the picks in this session and run the repo's checks, answer follow-ups, or hand an idea to the skill they name.

## The ideas file

A ranked-ideas run is worth a file: `ideas/<focus slug>.md` in the project's store (`agent-notes root --ensure` prints it, and the checkout sees it as `.agents/store`), never committed. It holds each idea with its basis, payoff and status, plus the rejected ones with a reason, so a rerun can read it first, re-check carried-over ideas against the code and not re-propose what was rejected unless the reason no longer holds. Update the status when ideas are picked or built. Skip the file when the ask was answered in chat.

## Privacy

Transcripts, pi sessions and shell history are private.

- Their text never goes to disk, the ideas file included: paraphrase the friction. Never quote a secret, and quote a phrase rather than a passage. Work profile material is paraphrased, never quoted.
- Search queries never carry text from transcripts or shell history.
- Every subagent brief repeats these rules.
