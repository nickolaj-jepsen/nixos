# Structure

Code shapes that turn one behaviour change into an N-file edit. These are design calls: in `diff`/`touched` scope fix only what the current change introduced; everywhere else, and for pre-existing sites the change merely brushes, report. Tells that span files need a grep across the repo; a hit in the open file alone is not a finding.

## Guard: don't trade churn for abstraction

This bounds every entry below. A wrong abstraction converts shotgun surgery (one change, many files) into divergent change (one file, every unrelated change), which is worse.

- Consolidate only on evidence that the copies **must** change together: tag-along commits from `cochange.py`, the same fix applied to each copy in history, or a drift bug.
- **Duplicated knowledge** (business rule, validation, pricing, regex, protocol constant) is unified even at two copies: divergence is a bug, so the duplication is its own evidence. Code that merely looks alike but changes for different reasons stays separate. New helpers: rule of three.
- Never suggest a directory reorganization, a new codegen pipeline for fewer than three representations, or one registry that every layer imports.

## Report shape

Each structure finding in the report carries:

- **Sites**: every `path:symbol` that must move together, not just the one in scope.
- **Evidence**: tag-along counts when mined, commits that edited all sites at once, or a drift bug. With none, say "no co-change evidence" and rank it last.
- **Shape**: the smallest change that removes the coupling, and what a future change then touches. No shape that fails the guard above.

Title each finding by the coupling ("agent guardrails are hand-copied per agent leaf"), not by the symptom at one site ("opencode has no guardrails"). A site that has drifted from its copies is evidence for the finding, not a separate bug report.

## Patterns

### Wrong abstraction already in place

- **Tell**: boolean/enum mode params that route to caller-specific paths inside shared code; caller-identity checks (`if source == "checkout"`, `if (opts.fromAdmin)`); options bags of 6+ optional flags, each used by one caller; base class, generic helper or `utils` with one caller; a shared module that tag-alongs with many unrelated features.
- **Do**: in `diff`, if the change adds a flag or branch to shared code that only one caller takes, give that caller its own code instead. Report: the shared symbol, each caller with the branches only it uses, co-change numbers; shape: inline back into callers, delete each caller's dead branches, re-extract only what is truly common.
- **Keep when**: the parameter is a real input to the shared logic that any caller could pass (rounding mode, timeout, page size, locale), not a switch to one caller's path.

### Hand-synced parallel registries

One set of variants (statuses, kinds, providers, tool names, flags) spelled out in N places: enum, handler switch, label map, icon/color map, i18n keys, analytics map, frontend copy of the enum, DB check constraint, docs table, test list.

- **Tell**: the same 3+ literals or enum members in 3+ files; several `switch`/`match` on the same discriminant (`kind`, `type`, `status`) in different modules; dicts keyed by the same enum in different files (`LABELS`, `ICONS`, `HANDLERS`); `default:` arms that swallow unknown variants; "keep in sync with" / "also update" comments; feature commits creating the same file stem in 4+ directories (`models/foo`, `schemas/foo`, `mocks/foo`, `fixtures/foo`).
- **Do**: in `diff`, a new variant map or switch gets a compiler reminder instead of silence: an exhaustive mapping or a `never`/`assert_never` arm, never a swallowing default. Report: every site, the variant commits that touched them together; shape: within one layer, one record per variant (label, icon, handler together) with the rest derived; across layers, exhaustiveness checks so the compiler lists the sites; across a wire boundary, a contract check, or codegen only if the repo already generates across it.
- **Keep when**: variants live in different bounded contexts with their own exhaustive mapping; a factory switch picking a class; two adjacent sites in one file; a test-per-source or framework-mandated layout (Rails, Django apps); a `default` that handles values arriving from outside (wire, DB, user input, newer clients), where unknown variants are real.

```ts
// before: silent when a Kind is added
const LABELS: Record<string, string> = { a: "A", b: "B" };
// after: adding a Kind fails to compile here
const LABELS = { a: "A", b: "B" } satisfies Record<Kind, string>;
```

### Hand-maintained duplicate schemas

The same data shape written by hand in several representations: TS interface + Zod schema + OpenAPI + Pydantic model + SQL DDL + GraphQL type.

- **Tell**: `interface Foo` next to a separately written `FooSchema = z.object(...)`; the same field list in `.py`, `.ts` and `.sql`/`.graphql`/`.yaml`; hand-written client request/response types while an OpenAPI or proto spec exists in the repo.
- **Do**: in `diff`, a new second representation is inferred from the first (`z.infer`, `TypedDict` from the model, ORM types) rather than written out. Report: each representation, fields added in lockstep across them; shape: one source with inference, or codegen only when 3+ representations exist or drift already caused a bug; otherwise a contract test that fails on divergence.
- **Keep when**: a public versioned DTO deliberately decoupled from the internal model; database migrations (append-only history, never derived); tiny projects where the pipeline costs more than the sync.

### Duplicated knowledge

A helper, validation rule, regex or constant written again instead of reused; a handler copy-pasted with renamed variables. Agents do this across sessions because the original was outside their context.

- **Tell**: near-identical names across modules (`format_date`, `formatDate`, `fmt_date`); the same regex, URL, magic number or validation rule defined twice (grep the literal); a new function calling most of the same non-builtin functions as an existing one; clone-detector hits (jscpd, PMD CPD, pylint `duplicate-code`); files that co-change with no import between them.
- **Do**: in `diff`, before keeping a new helper, grep for an existing one; if it fits, call it and delete the new copy. A business rule the change copied is unified now. Report: each copy, how they already differ, commits that patched more than one; shape: the canonical home and which copies collapse into it.
- **Keep when**: architecture- or framework-mandated skeletons (module wrappers, handler signatures, leaf boilerplate); tests (DAMP beats DRY there); near-fit helpers whose reuse would couple unrelated domains; duplication across service or team boundaries where a shared library costs more; copies that already differ on purpose.

### Duplicated values across code, config and CI

One literal (project version, runtime version, port, URL, timeout, image tag) in `package.json`, `__version__`, Dockerfile, CI YAML, `.tool-versions` and manifests (copies in prose docs are `docs.md` findings, not sites here); per-environment config files or CI jobs that are near-copies.

- **Tell**: `grep -rF "<current version>"` hits in more than one non-lockfile; the same runtime pin in CI, Dockerfile and a version file; a port/host/path in 3+ files; staging and prod files differing in a few lines; release commits touching 4+ files only to change a number.
- **Do**: in `diff`, a newly added copy reads from the existing source (CI reading `.nvmrc`, `importlib.metadata`, a Nix `let` binding or flake input, an env file). Report: every site holding the value, release commits that bumped them together; shape: the single source and how each site derives from it, or a test asserting the copies match when deriving is awkward.
- **Keep when**: copies already checked by a test or CI step; intentionally different pins (multi-runtime test matrix); explicit production config kept for auditability; a matrix or deep YAML anchors that would hurt readability of a small file; tests hardcoding expected values on purpose; lockfiles and generated files.

### Hub files every addition must edit

Adding a module means editing a shared list: `index.ts` barrels of `export * from`, `__init__.py`/`mod.rs` re-exports, plugin/command/route arrays, central import lists, docs nav (`mkdocs.yml`, sidebars).

- **Tell**: top-churn files that are mostly import/export/list lines; `index.(ts|js)` of only re-exports; siblings importing through `./index`; import cycles through a barrel; arrays of imported symbols growing with module count; commits that add a file and also edit the registry in the same directory.
- **Do**: in `diff`, if the repo already discovers by convention (globbing, filesystem routing, auto-imported leaves), don't add a manual registration; import directly instead of through an internal barrel. Report: the hub, the share of feature commits that touch it (tag-along count); shape: filesystem globbing, `import.meta.glob`, entry points or a generated registry, so a feature is one new file.
- **Keep when**: a package's public entry point; framework-required index files; order or priority matters; explicitness aids security review; a short list in a small codebase. Prefer globbing or codegen over registration by import side effect or decorator, which causes ordering bugs and defeats tree-shaking.

### Speculative indirection

Interfaces with one implementation, factories/strategies for a second case that never came, `*Service`/`*Manager`/`*Provider` wrappers that only forward, controller → service → repository → DTO → mapper stacks where most layers copy fields one-to-one.

- **Tell**: an interface, protocol or trait with exactly one non-test implementation; a body that is one call forwarding the same args (`return this.repo.getUser(id)`); mappers assigning every field `a.x = b.x`; adjacent layers with near-identical signatures; adding a field touches 4+ layer directories.
- **Do**: in `diff`, inline what the change introduced: the single-impl interface, the forwarding wrapper. A named single-use helper is not churn; leave it. Report: each layer a one-field change passes through, commits that did exactly that; shape: which layers collapse and which boundary stays.
- **Keep when**: seams at real I/O (clock, HTTP client, repository) whose other implementation is a test fake; an interface or layer the framework or DI container requires; public versioned API vs internal model; persistence vs domain under different owners; trust boundaries, anti-corruption layers, published plugin points; wrappers adding behaviour (retries, auth, error or unit translation).

### Defensive code for impossible states

`try`/`except` around code that can't throw, null checks on values the types guarantee, `default` arms on exhaustively handled enums, catch-log-continue, chained fallbacks, returning defaults instead of raising. Each phantom branch needs a test that forces the impossible state, and every invariant change must update the guards.

- **Tell**: `except(Exception)?:` followed by `pass`/`continue`/`return None|[]|{}`; empty or log-only catch blocks; `?? []`, `|| {}` on non-nullable types; `default`/`else` on a sealed type already fully matched; unnecessary-condition and unreachable-code linter hits (typescript-eslint `no-unnecessary-condition`, mypy `--warn-unreachable`).
- **Do**: in `diff`, remove guards the change added inside trusted code, narrow broad catches the change added to the exception actually handled, replace swallowing defaults with exhaustiveness checks. Name in the verdict any test that only reaches the removed branch; the tests pass deletes it, not this one. Report: the guards, the tests that force them; shape: validate at the boundary, trust inside.
- **Keep when**: top-level request/process handlers converting errors to responses; worker or daemon loops where one item must not kill the process, with the error logged with context; best-effort side effects (telemetry, cache warm-up) marked as such; real trust boundaries, including typed values that come from parsed JSON, env or untyped callers; a guard at a public entry point of untyped code; lookups where a default is the documented contract (`dict.get`, config with defaults). "fallback" in a name is not a tell on its own (locale, font, cache-miss paths).

### Backward-compatibility shims for code nobody external uses

Old names kept alive after a rename or move: re-exports from the old module, `oldName = newName`, deprecated wrappers, `foo_v2` beside `foo`, optional params kept for removed behaviour, `// removed: foo()` tombstones, dual paths behind a flag. Both paths then need tests and upkeep, and later changes hit one or must hit both.

- **Tell**: `legacy|deprecated|backwards?[ -]?compat|for compatibility|old name|alias for|kept for` in non-public code; re-export-only modules added in a move commit; `foo`/`fooNew`/`fooLegacy` pairs; `^\s*(//|#)\s*(removed|deleted|deprecated)\b`.
- **Do**: in `diff`, if the change itself renamed or moved the symbol and every caller is in this repo, update them and drop the shim; delete tombstones. Report: shim, old and new names, remaining callers in-repo; shape: the one-change rename.
- **Keep when**: anything with consumers outside the repo, assumed public until shown otherwise: published libraries, HTTP/RPC APIs, flake or package outputs, org-shared modules, config formats and option names users set, DB schemas under rolling deploys, persisted state paths and on-disk formats. Deprecation windows with a scheduled removal.

### Dead code and over-wide exports

Unused functions, exports, files, commented-out blocks; exports nobody imports; imports reaching into another package's internals. Dead code still has to compile through every rename, type change and dependency bump, and grep finds it, so agents faithfully update it. Internals imported across packages break on every refactor of their owner.

- **Tell**: unused-symbol tool hits (knip, vulture, Go `deadcode`, ruff `ERA001`); tests whose only subject is an unused function; `@VisibleForTesting` / "exported for tests" (also routed here from `tests.md`); `from pkg._private import`, `../other-pkg/src/internal/` paths.
- **Do**: in `diff`, when the change replaces a path, delete the old one; tests and docs that cover only it go in the verdict for their own pass. Don't add exports the change doesn't import. Report: each unused symbol with the tool output, tests that only cover it, cross-package internal imports; shape: delete, un-export, or route through the owner's public entry point.
- **Keep when**: public library API unused internally; entry points reached by reflection, plugins, framework conventions, config or CLI registration; a kill-switch path kept for rollback; code the branch's own later commits start using. `ERA001` hits that are illustrative examples or commands get reviewed, not auto-deleted.

Unused dependencies and finished feature flags are `repo.md` findings. Comment-only clutter in these files (restating code, verbose docstrings) is `prune-comments`/`prune-hard` territory; coupling comments go to `comments.md`.

## Sources

- John Ousterhout, _A Philosophy of Software Design_: change amplification, pass-through methods, information leakage.
- Sandi Metz, "The Wrong Abstraction": https://sandimetz.com/blog/2016/1/20/the-wrong-abstraction
- Kent C. Dodds, "AHA Programming": https://kentcdodds.com/blog/aha-programming
- Refactoring.guru, Shotgun Surgery vs Divergent Change: https://refactoring.guru/smells/shotgun-surgery
- Connascence (strength, locality, degree): https://connascence.io/
- Adam Tornhill, "Kill the Clones": https://adamtornhill.com/articles/aspnetclones/killtheclones.html
- TkDodo, "Please Stop Using Barrel Files": https://tkdodo.eu/blog/please-stop-using-barrel-files
