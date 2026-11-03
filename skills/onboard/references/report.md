# Report structure

Keep the section order. Write "none" rather than dropping a section. A quiz the user asks for goes last, under `## Quiz`. Mark the header **not run** when the project never ran, and **short** on a short overview: a rerun treats both as unfinished.

## `overview.md`

```markdown
# <project>: overview

<commit> · <date> · <ran | not run> · <full | short> · Looked at: <areas, history usable or not>

## What it does

## How to run it

Commands that worked, each one verified. Then the deferred commands, each with what it needs.

## Core features

For each: what it's for, how to do it (command, URL or API call), what you should see, **ran it** or **docs only**, and a screenshot or text capture if there is one. Mark the traced feature.

## Architecture

The map, with a diagram.

## Traced action

From entry to storage and back, with each boundary.

## Design choices

Each with its label (**stated**, **inferred**, **accidental**, **unknown**) and its evidence.

## Claims that failed

What a doc, comment, test or prediction said, and what actually happened.

## Open questions

## Dive candidates

Ranked, each with its reason and `/onboard <subsystem>`.
```

A short overview, written when a subsystem is the first thing asked for, keeps only the header, What it does, How to run it, and an Architecture section that shows where the subsystem sits.

## `<subsystem>.md`

```markdown
# <project>: <subsystem>

<commit> · <date> · <ran | not run>

## Purpose and boundaries

What it owns, what it doesn't, and what crosses the edge. One line on how users encounter it.

## Internal map

## Traced flow

## Invariants and failure handling

What must stay true, and what happens when a dependency fails. Say which you tested.

## Design choices

## Claims that failed

## Deferred

Exact commands for what needed the user, each with what it needs.

## Open questions
```
