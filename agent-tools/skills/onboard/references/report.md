# Report structure

A report is written for someone who will work in the project, not as a record of the run. Keep the section order. Write "none" rather than dropping a section. A quiz the user asks for goes last, under `## Quiz`. Mark the header **not run** when the project never ran, and **short** on a short overview: a rerun treats both as unfinished.

Each report has an evidence file beside it, `<report name>-evidence.md`, linked from the header (template at the end). How you checked something, the probes, the scripts in the clone and the predictions that turned out wrong go there and nowhere else in the report.

Rules shared by both reports:

- **Terms:** define each project term in plain words at its first use, and never cite a decision or rule ID (such as P3 or D4) without saying what it decided.
- **How you know:** never mention probes, the clone or its logs. State what is true; the evidence file says how you found it.
- **Similar projects:** 2–4 well-known projects, one or two lines each: what this one shares with each, and what it does differently. Each says its source: **stated** (the project's own docs name it) or **researched** (a cited page about the other project). Prefer stated. Something you remember can start a search but is never a source on its own.
- **Getting started:** the steps from a fresh clone to a first visible result, each one run in the clone. For a library, a minimal code sample that you ran, shown in full with its output, not as a pointer to where it came from. Leave out anything you didn't run.
- **Walkthroughs:** one per traced action, as 5–8 numbered steps. Each step is one sentence on what happens and why it matters for the feature, then `path` plus symbol. One sequence diagram. No predictions, probe output, commit logs or call chains.
- **Invariants and boundaries:** what must stay true and what happens when a dependency fails, with a "tested by" column filled from reading the tests (`path` plus test name, or "none").
- **Where the docs are wrong:** what the project's docs, comments, READMEs or config say that isn't true, and what actually happens. Never your own predictions, test quality, or failures caused by this machine.
- **Open questions:** only questions whose answer would change how someone uses or extends this part, at most five. Small quirks are dropped.
- **Commands:** a table of the project's own commands in this report's scope. Columns: command, what it shows, result (**passed**, **failed** or **skipped**), and why, in a few words, for a failure or a skip. A failure caused by this machine is a row here with its cause. Never list scripts you wrote in the clone.

## `overview.md`

```markdown
# <project>: overview

<commit> · <date> · <ran | not run> · <full | short> · Looked at: <areas, history usable or not> · [Evidence](overview-evidence.md)

## What it's for

The problem it solves and for whom, in the project's own terms.

## Similar projects

## Getting started

## Core features

For each: what it's for, how to do it (command, URL or API call), what you should see, **ran it**, **tests only** or **docs only**, and a screenshot or text capture if there is one. Mark the traced feature.

## Where it sits

What it talks to and what talks to it, with a context diagram.

## Codemap

The main parts and how they relate, with a diagram. For each part: what it does and where to find it. Not how each part works inside.

## Walkthroughs

## Invariants and boundaries

## Design choices

Each with its label (**stated**, **inferred**, **accidental**, **unknown**) and its evidence.

## Where the docs are wrong

## Open questions

## Commands

## Dive candidates

Ranked, each with its reason and `/onboard <subsystem>`.
```

A short overview, written when a subsystem is the first thing asked for, keeps only the header, What it's for, Getting started, a Where it sits section that shows where the subsystem sits, and Commands.

## `<subsystem>.md`

```markdown
# <project>: <subsystem>

<commit> · <date> · <ran | not run> · [Evidence](<subsystem>-evidence.md)

## What it's for

What it owns, what it doesn't, and how users encounter it.

## Similar projects

Only when the subsystem has a space of its own; otherwise "none: no space of its own".

## Getting started

When it has a surface of its own, such as an API to call; otherwise point to the overview.

## Where it sits

What crosses its edges, in both directions, with a diagram.

## Codemap

## Walkthroughs

## Invariants and boundaries

## Design choices

## Where the docs are wrong

## Open questions

## Commands
```

## `<report name>-evidence.md`

Written in the same run as its report and redone on a rerun. The citation check covers the report, not this file, since it names scripts that exist only in the clone.

```markdown
# <project>: <report> evidence

<commit> · <date> · trace method: <debugger | tracer | spans | state inspection>

## <walkthrough name>

One line per step: what you saw (an output, a stored row, a log line) and how (the command or script in the clone).

## Predictions that were wrong

"Expected X, saw Y", one line each.
```
