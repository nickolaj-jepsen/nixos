# Comments

Same-line verbosity (restating the adjacent code or literal, signature-restating docstrings, banners) is `prune-comments`/`prune-hard` territory: leave it alone here, don't list it. Skip generated and vendored files entirely; their comments are rewritten by the generator or upstream.

This file covers comments coupled to something _outside_ themselves: another file, the call graph, a list kept elsewhere, the diff that produced them. Each one must be edited when that other thing changes, and nobody remembers to.

### Positional references

- **Tell**: `path/to/file.ext:123`, `line 88`, `lines 40-60`, `L42` meaning a source line; `github.com/…/blob/(main|master|HEAD)/…#L40`; `see above`, `see below`, `the function above`, `defined earlier in this file`; `# handled in src/auth/session.ts`; links to Slack threads, Google Docs or localhost with no summary of the point. Any path token in a comment that fails `test -e` is already stale.
- **Do**: delete when the code reads fine without it. Otherwise point by **name**, not location: `see parse_header`, which grep, LSP and rename tooling all resolve. Prefer the language's checked link syntax where it exists (`{@link Foo}`, rustdoc ``[`Foo`]``, Sphinx `:func:`). For an unavoidable URL, pin it to a commit SHA or tag and summarize the linked point inline so the comment still works once the link dies. A stale path with no symbol to name: fix it if the target is obvious, otherwise delete.
- **Keep when**: SHA-pinned permalinks; external specs by section (`RFC 9110 §15.5`) and upstream issue links; one stable pointer to a doc that holds the explanation (`see docs/secrets.md`), as long as the path exists. Not a finding: `L1`/`L2` cache, `layer 2`, `line 1 of the header` in protocol code.

```text
# see utils/headers.py:142 for the format       → # format: see parse_header
// fix from github.com/x/y/blob/main/a.go#L40   → // workaround for x/y#812 (keepalive drops first frame)
```

### Callers, consumers and siblings

- **Tell**: `(used|called|invoked|consumed|imported) (by|from|in) …` naming specific callers; `called from OrderService.submit`; `the admin dashboard and billing worker use this`; `See also:` / `@see` lists with more than two entries; a docstring that is mostly about who else exists.
- **Do**: replace it with the contract: inputs, outputs, errors, invariants, side effects. If a caller imposes a real constraint, state the constraint, not the caller. Before deleting, grep the named caller: if it shows up as a plain call site, the comment is redundant.
- **Keep when**: callers grep can't find: reflection or string dispatch, framework lifecycle hooks, cron/queue entry points, webhooks, config/template invocations, consumers in another repo. `invoked by the nightly cron in the infra repo` earns its place. Not a finding: preconditions the caller establishes (`caller holds mu`), which are contract.

```text
# Used by checkout and the mobile API.           → # Payload shape is frozen: mobile v2 clients parse it.
```

### Mirror and keep-in-sync markers

- **Tell**: `mirrors`, `matches the enum in`, `same as`, `keep in sync with`, `must match`, `also update`, `if you change this, change …`, when followed by another file, symbol or system.
- **Do**: these flag duplication; the comment is the only trap marker, so deleting it alone makes things worse. Remove it only in the same edit that removes the duplication or adds a check that fails on divergence. Otherwise keep it, name the other site by symbol (a path only when the other side has no symbol, e.g. a SQL or YAML file), and emit a verdict routing the duplication to `structure.md` (hand-synced registries).
- **Keep when**: cross-language duplication with no codegen. Keep the marker, ideally paired with a check.

### Enumerations and counts of another source of truth

- **Tell**: a comment listing what lives elsewhere: env keys, directory contents, enum members, supported providers, config fields, routes, flags. Counts of things defined elsewhere: `# the 3 backends`, `handles all 5 event types`, `one of 12 modules`. A value restated from a constant defined in another file (`# retries 3 times` when `MAX_RETRIES` lives in config). Module docstrings or file headers inventorying the functions/classes below (`This file contains X, Y, Z`).
- **Do**: delete the list; if a reader needs to know where the list lives, point at it by name (`see Provider enum`, `keys: .env.example`). Drop the count or say "all". Name the constant instead of its value (`# retries up to MAX_RETRIES`). Module docstrings state purpose and invariants, not an inventory.
- **Keep when**: the list _is_ the source of truth (an exhaustive match whose comment is the only spec); the enumeration is a contract an external party depends on and nothing in-repo encodes it; the count is a constraint the adjacent code enforces (`# exactly 3 bytes: R, G, B`). Not a finding: unit-only comments (`# seconds`), especially on keys whose names an external schema fixes.

### Change narration

- **Tell**: comment starts with a change verb describing an edit to this code: `added`, `updated`, `changed`, `fixed`, `removed`, `refactored`, `replaced`, `renamed`, `moved`, `NEW:`, `FIX:`; review-addressed phrases: `per review`, `as requested`, `as discussed`, `PR #123`; header blocks `Revision History`, `Change Log`, `Modified by`, `Last updated`. Not a finding: the same words as domain terms (`Fixed-point math`, `Removed entries are tombstoned`).
- **Review prompts, not auto-delete**: `previously`, `no longer`, `used to`, `now uses`, `instead of`, `phase N`/`step N`, dates and `as of <month year>`. Act only when the comment makes sense solely to someone who read the diff or the conversation; these words also appear in real why-not comments (`use X instead of Y: Y deadlocks`) and algorithm names (`phase 1 of two-phase commit`).
- **Do**: delete the narration. If a lasting why is buried in it, rewrite that as a timeless present-tense comment about the current code (Ousterhout §16.3: the why lives in the code; the delta goes in the commit/PR).
- **Keep when**: public-API deprecation with a removal target (`@deprecated since 3.2, removed in 4.0`), `versionadded`/`versionchanged` in published docs; a rejected alternative with its reason; an incident cited because it _is_ the constraint (`don't batch: double charges, INC-123`); a workaround with its removal condition (`drop once lib >= 2.4`); immutable files whose job is to record a change (migrations).

```text
// Updated to use the new client per review; old one timed out
→ // 5s client timeout: upstream drops idle sockets at 6s
```

### Implementation leaking into interface docs

- **Tell**: a public docstring naming private identifiers (`_index`, `#cache`, `internal`) or private helpers it calls; `internally`, `under the hood`, `first it … then it …`, `iterates over`, `uses a dict/map`; numbered step lists describing internal steps.
- **Do**: keep only the contract (behaviour, params, errors, invariants, guarantees callers rely on) in the interface doc. Move a genuinely tricky step to an inline comment beside the code; drop the rest. A contract you can't state without the implementation is a design smell: report it, don't refactor.
- **Keep when**: performance or concurrency traits callers depend on (`O(n log n)`, `not thread-safe`, `blocks on network I/O`, `cached for 60s`), observable side effects and their order, and references to other public API (`same as load() but async`), which are all contract. Private helpers whose only reader is the implementer.

### Per-file headers that rot

- **Tell**: `File: utils.py` / `Filename:` lines; `@author`, `Author:`, `Maintainer:`; `Copyright (c) 2019-2025` year ranges bumped each year.
- **Do**: delete `File:` lines and authorship; git log holds them. **Never edit copyright or license headers**: report them (year ranges churn every file yearly; SPDX one-liners or open-ended ranges are the owner's call), and leave the decision to whoever owns legal.
- **Keep when**: legally required headers; vendored third-party files keeping upstream headers; `DO NOT EDIT, generated by X` banners, which prevent churn.

## Sources

- Wen, Nagy, Bavota, Lanza, _A Large-Scale Empirical Study on Code-Comment Inconsistencies_ (ICPC 2019): only 13–20% of code changes trigger a comment change; renames and literal changes are among the least likely to. https://www.inf.usi.ch/faculty/lanza/PUBS/P/Wen2019a.pdf
- John Ousterhout, _A Philosophy of Software Design_, ch.13 (cross-module comments, "Implementation Documentation Contaminates Interface") and §16.3 ("Comments belong in the code, not the commit log").
- matklad, _ARCHITECTURE.md_: name symbols instead of linking, since links go stale. https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html
- Connascence (locality and degree of coupling). https://connascence.io/
- Cody Oh, _Documentation rots, some kinds rot faster_. https://codyoh.substack.com/p/documentation-rots-some-kinds-rot
- Hillel Wayne, _Why Not Comments_. https://buttondown.com/hillelwayne/archive/why-not-comments/
- Bitcoin Core: yearly copyright bumps across every file (PR #26750); repeatedly proposed `-present` to stop it (PR #26817, closed unmerged). https://github.com/bitcoin/bitcoin/pull/26817
