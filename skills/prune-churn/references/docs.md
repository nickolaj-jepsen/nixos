# Docs and agent instruction files

For every block that restates something the code defines, take the first option that fits:

1. **Point**: delete the restatement and name where the truth lives (`see providers/`, `run just`, `--help`, the schema file). Before writing a pointer, check that the path or command actually exists.
2. **Generate**: only if humans need the list _and_ the repo already has a generator (cog/mdsh markers, a `docs` recipe, an options or OpenAPI renderer). Wire the block into that generator. Never add one.
3. **Execute**: only if a doc-test runner is already configured. Otherwise trim or delete instead.
4. **Keep as prose**: only what code can't express, such as why, constraints, rejected alternatives, invariants and absences ("core never imports the HTTP layer").

Skip generated output (`<!-- generated -->`, `[[[cog`, files a `docs` recipe writes); edit the generator's source instead. Help text in code (`--help` strings, justfile `[doc]`) is the source of truth to point at, not a finding. Comments and docstrings go to `comments.md`. Plain wordiness with no coupling belongs to `prune-comments`/`prune-hard`; don't catalog it here.

Judge line by line, never by heading: a section titled `Architecture` can hold the one trap worth keeping. When a finding needs another file changed (the canonical copy, the instruction file), edit only this file if the other side already holds the fact; otherwise report it and leave both.

## Prose docs

### Inventories: feature lists, counts, trees, file tours

- **Tell**:
  - Headings like `Features`, `Supported X`, `Available commands`, `Project Structure`, `Codebase Overview`, `Tech Stack`; tree glyphs (`├──`, `│`); `path/file.ext — handles X` tours.
  - Bullets or table rows that map 1:1 to files in a directory, enum members, registry keys or subcommands (compare with `ls` or the enum).
  - Counts of code-derivable nouns (`12 providers`, `three output modes`, `5 hosts`). Algorithm terms (`two-phase`, `three-way merge`) are not counts.
- **Do**: replace the list with the rule that generates it plus a pointer. Delete counts outright. If a self-listing command exists, point to it.
- **Keep when**: the set is stable by definition (HTTP verbs); a user-facing README's quickstart of the few most-used commands (trim the deep cuts and add the pointer, but never cut it to the pointer alone); a landing page where the curated pitch is the product (still drop the count); a template repo whose layout is the deliverable; a codemap of stable top-level boundaries that says what each is _for_ and what it must not touch, not one line per file.

```markdown
<!-- before -->

We support 12 providers:

- `providers/aws.py` — AWS
- `providers/gcp.py` — Google Cloud
- ...
  <!-- after -->
  One module per provider under `providers/`, each registered with `@provider("name")`.
```

### Reference tables that mirror a schema

- **Tell**: `Name | Type | Default | Description` tables whose rows match parser options, settings fields or Nix/pydantic/zod options; env var tables whose names appear in `os.environ`/`process.env`/`std::env` reads; hand-written endpoint docs next to an OpenAPI spec; "timeout of 30s" next to `TIMEOUT = 30`. A documented default that differs from the code is proof of drift.
- **Do**: point at the schema or `--help`. If the repo already renders the schema (options doc, OpenAPI docs, typer/clap markdown), point at that output. Narrative guides describe behaviour without the number ("configurable timeout, see `--help`").
- **Keep when**: a tiny surface (3–4 options) unlikely to grow; the subset of an external API you rely on; published docs whose readers never see the source (installed CLI, library users) and no generator exists. Keep those rows, fix drifted ones.

### Pasted program output

- **Tell**: fenced blocks that start with `$ cmd` and then show output; `Usage:`/`Options:` blocks in argparse/clap/click/cobra format; hand-typed JSON or YAML responses whose fields appear in a model; console blocks longer than about 20 lines.
- **Do**: if a cog/mdsh-style generator exists, splice the output in with it. Otherwise cut to a short fragment with `...` and add "run `tool --help`". Full help pastes become the pointer alone.
- **Keep when**: a tutorial deliberately freezes one run and labels it as an example; the output is environment-specific (elide it and say so); `git log` shows the producing code hasn't changed since the paste.

### Code examples nothing runs

- **Tell**: ` ```python`/`ts`/`go`/`rust` blocks in Markdown with no doc-test runner configured; snippets calling symbols that no longer resolve (grep each one); several long examples that walk through the same API.
- **Do**:
  - Fix every dead symbol first; that is a bug, not churn.
  - If a runner exists (Go `Example*` functions, `--doctest-glob`, `cargo test --doc` over an included README), move the example under it.
  - If `examples/` is built in CI and the docs already include from it, point there.
  - Otherwise shrink each example to the calls that show intent, and delete repeats.
- **Keep when**: the one quickstart example in a library or CLI README (keep it short and correct; never delete it); the block is marked pseudo-code; the snippet needs live infrastructure and is short.

### Version- and time-pinned prose

- **Tell**: semver strings (`v?\d+\.\d+(\.\d+)?`) that duplicate the manifest version; pinned install lines (`==1.4.2`, `@1.4`); `as of <date>`, `at the time of writing`, `latest version is`, `coming soon`; years in running prose. `currently` alone is weak; flag it only next to a date or version.
- **Do**:
  - Minimum versions that duplicate `engines`/`requires-python`/`rust-version`: point at the manifest.
  - Pins that matter for reproducibility: source them from the repo's existing substitution (`|version|`, mkdocs macros); with none, leave the pin. Never just unpin.
  - Rewrite time-relative claims in timeless present tense, or delete them.
- **Keep when**: CHANGELOG, release notes, a migration guide for a specific version jump, an ADR or a postmortem (dated by design, never updated); `versionadded`/"new in X.Y" markers on API entries (permanent facts); copyright lines and citations.

### Line and location references

- **Tell**: `file.ext:123`, `line 88`, `lines 40-60`; `github.com/…/blob/(main|master|HEAD)/…#L40`; `the third section below`; backticked paths that fail `test -e`.
- **Do**: reference by symbol, heading or file name instead of position. A stale path: fix it if the target is obvious, otherwise delete the reference.
- **Keep when**: the link is pinned to a commit SHA or tag; the doc is an ADR or postmortem describing a past state.

### Same fact in several docs

- **Tell**: identical setup or command blocks, or near-duplicate paragraphs, across README, CONTRIBUTING, `docs/` and module READMEs (grep a distinctive line of the block); several `Getting Started`/`Setup`/`Development` sections.
- **Do**: one canonical home per fact: dev setup and workflow in CONTRIBUTING or `docs/`, user install and usage in README, a module's internals in its own doc. If this file is the non-canonical copy and the canonical one already holds the fact, replace the copy with a one-line pointer by name or relative link. If this file is canonical, or the homes are ambiguous, leave it and report. Where a copy must exist (a registry renders only the README), transclude it with the repo's existing include mechanism.
- **Keep when**: an audience-specific summary differs on purpose (a two-line README teaser over a full guide); one-line safety or approval rules in an agent entry file (see below).

### Inferable boilerplate

- **Tell**: generic `Installation` (clone, `npm install`), `Prerequisites: Node.js`, fork-and-PR `Contributing`; explanations of framework conventions; script or dependency lists mirroring `package.json`/`pyproject`/justfile; module-by-module "How it works" narration of what the code plainly does.
- **Do**: delete only when **both** hold: no human reader needs it, _and_ a competent reader or agent would infer it from the code or manifest within about 10 seconds. Keep intent, constraints, gotchas, non-default tooling and approval requirements.
- **Keep when**: a public library or product (keep a minimal install/usage section, no copied dependency lists); a deliberate onboarding path or non-developer audience; a non-default setup step that actually trips people up.

### Screenshots and binary diagrams

- **Tell**: `*.png`/`*.gif`/`*.cast` under `docs/` that show terminals or code; `*.drawio.png`/`*.vsdx` with no text source.
- **Do**: replace terminal and code screenshots with text or a pointer. Convert binary diagrams of code structure to Mermaid only if the repo already renders it; otherwise report. Report UI screenshots; don't propose a capture pipeline. Leave the image file itself; orphaned assets are `repo.md` territory.
- **Keep when**: a logo or branding; an end-user product doc where visuals are the guidance; an ADR capturing a past state.

## Agent instruction files

Any file an agent loads as standing instructions (e.g. `AGENTS.md`, `CLAUDE.md`, Cursor or Copilot rule files), including nested per-directory variants. Agents follow these literally, so a stale line misleads instead of merely sitting there. Evidence (Gloaguen et al.): generated context files slightly lower task success, hand-written ones barely help, both raise cost, and repository overviews don't help.

Keep a line only if **both** hold: an agent doing a task would not pick it up from the code it reads anyway, the manifest or `--help`; _and_ without it the agent would plausibly make a mistake or stop to ask. Line count prompts a review; on its own it is never a violation.

### Drop

- **Tell**:
  - Overview, architecture, directory-structure, tech-stack and key-files prose; tree glyphs; per-module descriptions; counts. This is `/init` output.
  - Full script lists copied from `package.json`/Makefile/justfile, and descriptions that only restate the name (`pnpm lint` — lints).
  - Style rules that a formatter or linter config already enforces.
  - Generic advice (`best practices`, `clean code`, `well-tested`, `follow existing patterns`, `be careful`).
  - `Recent changes` sections.
  - Sync policies tied to an enumeration ("update the module list when you add a module"). They build the churn into every PR.
  - Paths or symbols that no longer resolve.
- **Do**: delete. Point at the self-listing command (`run just`, `pnpm run`) in place of a script list. Fix a dead path when the renamed target is obvious.
- **Keep when**: the line carries a trap even under a descriptive heading (keep the trap, drop the description around it); a framework is newer than the model's training data and needs a compressed index of its docs; a routing rule saying where new non-inferable knowledge goes ("new traps go in the matching `docs/` page").

### Keep, tersely

- The few commands an agent must run (verify, test, format, the one to use instead of the obvious one), each with what the manifest can't hold: `needs explicit approval`, `slow`, `run before finishing`, `pass a path, not a name`.
- Traps and non-inferable invariants ("every file under `modules/` is auto-imported, so gate it").
- Non-default tooling and environment quirks (uv/pnpm, "no global installs; use the devshell").
- Approval and safety gates (never force-push, deploys need sign-off). Restate these one line each in the entry file even if canonical elsewhere; agents don't reliably follow pointers.
- Settled decisions the code can't show, as the rule plus the rejected alternative.
- A short routing table: topic → doc by name.

```markdown
<!-- before -->

- `pnpm test` — runs tests
- `pnpm lint` — lints the code
- `pnpm build` — builds the app
- `pnpm deploy` — deploys to production
  <!-- after -->
  `pnpm run` lists scripts. Before finishing: `pnpm test && pnpm lint`. `pnpm deploy` ships to production: needs explicit user approval.
```

### Duplicate instruction files

- **Tell**: two or more instruction files with near-identical content.
- **Do**: `AGENTS.md` is canonical when it exists. A tool file that supports includes (`CLAUDE.md`) becomes `@AGENTS.md` plus only its tool-specific lines. For tools without includes, report the duplication. An include is the correct pattern, not a duplicate.
- **Keep when**: the lines are tool-specific (hooks, a tool's own commands or settings).

### Settled conventions repeated per feature

- **Tell**: a feature README, design note or module doc restating a project-wide decision ("we use `fetch`, not axios", "errors return `Result`", "tests live next to source").
- **Do**: if the instruction file or a lint rule already states it, delete the per-feature copy. If no central home states it, report it as a candidate line for the instruction file; don't move it yourself.
- **Keep when**: the doc records a local exception to the convention and why; a deliberate migration is in flight (one line in the instruction file says which direction).

## Sources

- matklad, "ARCHITECTURE.md": https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html
- Google documentation best practices: https://google.github.io/styleguide/docguide/best_practices.html
- Gloaguen et al., "Evaluating AGENTS.md" (arXiv 2602.11988): https://arxiv.org/abs/2602.11988
- Addy Osmani, "Stop Using /init for AGENTS.md": https://addyosmani.com/blog/agents-md/
- Claude Code best practices (CLAUDE.md include/exclude): https://code.claude.com/docs/en/best-practices
- Diataxis, Reference: https://diataxis.fr/reference/
- Simon Willison, cog for `--help` in a README: https://til.simonwillison.net/python/cog-to-update-help-in-readme
- Go Blog, "Testable Examples in Go": https://go.dev/blog/examples
