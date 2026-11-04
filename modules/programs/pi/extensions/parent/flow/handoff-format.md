# The HANDOFF format

`HANDOFF.md` is the one file a plan hands to a run. `/flow` parses it before the
approval page, rewrites exactly one line in it (an item's `Tier:`), and its run
lead reads it as the plan. A file that does not parse is refused, and the
parser's errors go back to the planner.

`handoff-example.md`, beside this file, is a complete plan that parses. Read it
alongside these rules; tests parse it.

## Headings

One `#` title, then `##` sections in any order. Heading text is matched
case-sensitively and the required set must all be present.

Required:

- `## Mission` — why this exists, in prose.
- `## Smallest version` — one paragraph, then a `Not building:` line followed by
  its bullets. The bullets are what the smallest version leaves out on purpose.
- `## Scope` — `In:` bullets and, under `Out:`, what stays untouched.
- `## Context` — the repo, the base branch, the terms, the commands and their
  measured durations, and the repo-specific traps a builder needs first.
- `## Locked decisions` — three `###` subsections:
  - `### Yours` — stated by the owner, not to be re-litigated.
  - `### Defaults` — accepted recommendations; a builder may overturn one with
    evidence, and says so.
  - `### Mechanism uncertain` — optional. Each entry names its chosen mechanism
    and its fallback; the builder may switch to the fallback without stopping.
- `## Work items` — one `###` per item, no other `###` level inside this
  section.
- `## Budget` — all five bullets, `- New files: <n>`, `- New abstractions: <n>`,
  `- Lines: <n>`, `- Cost cap: $<n>`, `- Concurrency: <n>`.
- `## Stops` — what halts this run, including the owner's gates.

Optional, and each is kept verbatim for the approval page to render:

- `## Contracts` — `- C1 <name>: <shape>. Why: <reason>.`
- `## Trust boundaries`
- `## Review focus` — which risks a reviewer must cover, and by which item.
- `## Rules for this project`
- `## Stop conditions`
- `## Gotchas`
- `## Open questions` — `- Q1 <question>` bullets.
- `## Amendments` — the owner's later word, dated, appended; never rewritten.

## Decisions

A decision is one bullet, `- <ID> <text>`, where the ID is `U1`, `U2`, … under
`### Yours` and `D1`, `D2`, … elsewhere, running on across the three
subsections. Continuation lines and nested bullets belong to the decision above
them. A decision is copied into a later plan verbatim, ID included; new ones
continue the numbering.

A contract is `- C1 <name>: <shape>. Why: <reason>.`, numbered the same way. Its
`Why:` is required: a contract with no reason to exist is one to delete. A long
shape may continue on the following indented lines, which belong to the bullet;
`Why:` may then sit on any of them.

## Items

An item is `### <ID> <title>`, with the ID matching `G\d+`, `A\d+` or `S\d+`.
Items run in ID order on a tie; `Blocked by` decides the rest. A spike's title
ends `(spike, timebox <n>)` and the item carries a `- Why:` line saying what the
spike buys; without it, the spike is not worth its box.

The field bullets, each `- <Field>: <value>`:

- `- Blocked by:` — item IDs, comma-separated, or `none`. It must not name an
  item's own ID or an item that does not exist.
- `- Owns:` — the paths and globs the item may change. The value may be the rest
  of the line or the nested bullets under it. Two items in flight never overlap.
- `- New:` — what it adds, in prose: systems, files, abstractions.
- `- Tier: flash | deep` — which builder the item goes to. Exactly one value.
- `- Outcome:` — what is true when it is done. The value may be nested bullets.
- `- Acceptance:` — the command whose output proves the outcome, and what it
  must print. The value may be nested bullets.
- `- Constraints:` — the decisions and contracts the item is bound by.
- `- Why:` — spikes only.

An acceptance whose last line ends `(unverified)` is flagged on the approval
page: nobody has run it yet, so it proves nothing until someone does.

## Naming

- Paths are relative to the repository root, as written in `Context`.
- A command sits inside backticks and is runnable as written.
- The approval page rewrites one line: the `Tier:` line of an item whose tier
  the owner changes. Nothing else in the file is edited by `/flow`.
