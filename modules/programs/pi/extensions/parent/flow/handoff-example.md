# A CSV export button: handoff

## Mission

The dashboard prints a table that people screenshot into spreadsheets. Add an
export button that downloads the table as CSV, so a report is a file rather than
an image.

## Smallest version

One button on the existing report page that downloads the current table as CSV,
with the same columns and the same filters the table already applies.

Not building:

- an export format picker;
- server-side exports of tables nobody has opened;
- a scheduled email of the export;
- any change to the table's own columns.

## Scope

In:

- `app/report/export.ts`, the CSV writer;
- the button on `app/report/page.tsx`;
- unit tests for the writer and one browser test for the button.

Out: every other page, every other format, and the column definitions, which
`app/report/columns.ts` owns.

## Context

- Repo `example/app`, base branch `main`.
- Unit tests: `pnpm test`, about 8 s today.
- Browser tests: `pnpm test:e2e`, about 90 s; they are not part of the pre-push
  hook.
- Every new file needs committing before the e2e run, which reads the built
  tree.

## Locked decisions

### Yours

- U1 CSV, not Excel. Why: the recipient opens it in a tool nobody here owns.
- U2 The button never waits on a network round trip. Why: the table is already
  in the page and the export is a formatting step.

### Defaults

- D1 The writer is a pure function taking rows and columns, so a unit test
  drives it without the page.
- D2 Quoting follows RFC 4180, with a test for a field holding a comma and a
  newline.

### Mechanism uncertain

- D3 The download uses an object URL and a hidden anchor. Fallback: the
  `download` attribute alone, if the object URL leaks in the browser test.

## Contracts

- C1 `toCsv(rows, columns) → string`: RFC 4180, no trailing newline, every value
  quoted only when it must be. Why: the writer is the only part a test can pin.

## Work items

### G0 The writer

- Blocked by: none
- Owns:
  - `app/report/export.ts`, `app/report/export.test.ts`
- New: the CSV writer
- Tier: flash
- Outcome: `toCsv` exists and is covered by `export.test.ts`.
- Acceptance:
  - `pnpm test app/report/export.test.ts` → all pass, including a field with a
    comma and a field with a newline.
- Constraints: C1, D2

### A1 The button

- Blocked by: G0
- Owns:
  - `app/report/page.tsx`, `app/report/export-button.test.ts`
- New: the export button
- Tier: flash
- Outcome: the report page shows one button that downloads the table as CSV.
- Acceptance:
  - `pnpm test:e2e report` → `PASS`, and the downloaded file's first line is the
    table's header row `(unverified)`.
- Constraints: U1, U2, C1, D3

### S1 A refactor worth it or not (spike, timebox 30)

- Blocked by: none
- Owns:
  - `app/report/notes/spike-export.md`
- New: a written finding, no code
- Tier: flash
- Outcome: a note saying whether the table's column definitions can be shared
  with the CSV writer, with the estimate for doing it.
- Acceptance: the note exists and names a decision.
- Constraints: none
- Why: a second copy of the column order is a real cost, and half an hour now
  settles whether it is one to pay.

## Budget

- New files: 5
- New abstractions: 1
- Lines: 220
- Cost cap: $2
- Concurrency: 2

## Stops

- G0: the owner reads the writer's interface before A1 lands on it.
- The final gate: the owner sees the downloaded file.

## Review focus

- A value holding a comma, a quote or a newline: covered by G0's acceptance.
- A download that leaves the page's filters behind: covered by A1's acceptance.

## Open questions

- Q1 Does the export need a filename that names the report's date range?

## Amendments

- 2026-03-01, owner: Q1 answered, the filename is `report-<from>-<to>.csv`, and
  A1 takes it.
