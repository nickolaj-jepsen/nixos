# Tests

A test is churn when it must be edited for a change that leaves behaviour intact: a refactor, one more registry item, a reworded string, a new field, a dependency bump. The cure is almost always the same: assert the observable outcome, not the path to it. Verbose comments inside test files are `prune-comments`/`prune-hard` territory; skip them here.

## Delete or rewrite

- **Delete** only a test that exercises no production logic: it asserts its own mock, a constant, a declaration, or a library. The verdict names why.
- **Rewrite** every other brittle test. Keep the behaviour it protected; change what it checks.
- Before deleting, confirm the production code it touches is covered by another test (coverage tooling if the repo has it, else grep for other tests reaching it). If not, rewrite it to assert the behaviour, or leave it and report.
- Edit only this file and its own snapshot/golden files. A fix that needs a new shared builder, fake or fixture, a production seam (injected clock, removed test-only export) or a new test dependency is reported with its sites and suggested shape.
- Use only libraries and helpers the repo already has. Tool names below are examples, not a shopping list.
- Verdicts: `deleted (mock-echo; parse() covered by test_import)`, `rewritten (call-shape → returned state)`, `report (User built by hand in 9 files → builder)`.

## Weakening is not a fix

When a test fails after your edit, the edit was wrong; revert it, not the test. Never get to green by weakening: exact→approx, `==`→`in`, specific→generic exception, matcher→`toBeTruthy`/`any()`, dropped assertions, added `skip`/`xfail`/`.only`/`@Disabled`/`#[ignore]`, snapshot update flags (`-u`, `--update-snapshots`), lowered coverage thresholds, `try/except` around the act, or production branches on test inputs or `NODE_ENV == 'test'`.

Narrowing an overspecified assertion to the facet a test is named for (the rewrites below) is not weakening; loosening that facet is.

When the change under review made one of these moves, report it (`report (assertion weakened: == → in)`); don't revert someone else's test. An existing assertion changed in a feature or fix is a review prompt that needs a one-line why, not a violation. A skip or retry with a linked issue is fine.

## Patterns

### Mock-echo

- **Tell**: the value stubbed in `mockReturnValue`/`mockResolvedValue`/`return_value=`/`thenReturn(...)` reappears in the final assert, and the SUT does nothing between them (no branching, filtering, mapping or error handling). Worse forms: `jest.mock`/`mock.patch` of the module that defines the function under test; `jest.spyOn(sut, ...)`/`patch.object(sut, ...)` then asserting that spy was called. Body is mock setup plus one assertion.
- **Do**: delete. If the SUT has an error or edge branch, keep one test for that branch. If the SUT would lose its last coverage, rewrite to one test with a real or existing fake dependency that asserts the transformation the SUT performs.
- **Keep when**: a thin adapter whose contract is "maps response A to domain B": one test with a realistic, ideally recorded, payload.

### Asserting calls on in-process collaborators

- **Tell**: `toHaveBeenCalledWith`/`toHaveBeenCalledTimes`, `assert_called_once_with`, `assert_has_calls`, `call_args`, `mock_calls`, `verify(...)`, `times(n)`, `InOrder` as the test's only checks, with no assertion on a return value or resulting state. Verifying that a query (`get*`/`find*`/`fetch*`/`load*`/`is*`) was called. Several mocks (`jest.mock('./...')`, `vi.mock('../...')`, `mock.patch('<own_pkg>.…')`) of fast, deterministic in-repo modules in a test that asserts only on them.
- **Do**: rewrite to assert the outcome: return value, resulting state, or an effect at the system boundary. Prefer the real collaborator, then an existing fake; if neither is cheap, report. Stub queries, never verify them. When one interaction is the behaviour, assert that one call, not the sequence.
- **Keep when**: boundary side effects with no observable state (email sent, message published, card charged, audit event); call count or order is the requirement (cache cuts backend reads, retry limit, rate limit, "never charge twice"); adapter/protocol code whose job is translating calls. A high call-assert ratio alone is normal in command-heavy code (notifiers, publishers). A repo that tests through mocked ports by design (London school, consistently): report once, don't rewrite file by file.

```ts
// before: breaks if save() is batched or renamed
expect(repo.save).toHaveBeenCalledWith({ id: 1, status: "paid" });
// after: the repo's in-memory repo, assert state
expect(await repo.get(1)).toMatchObject({ status: "paid" });
```

### Mocking libraries you don't own

- **Tell**: chained mocks (`session.query.return_value.filter.return_value.first.return_value = user`, `mockReturnThis()` chains); `mock.patch('requests.…'|'boto3.…'|'sqlalchemy.…')`, `jest.mock('axios'|'@aws-sdk/…')`; a `MagicMock` standing in for a session, cursor, connection or client; the app's own DB mocked. Swapping `.filter().first()` for `.one()` breaks the test with behaviour unchanged.
- **Do**: rewrite, cheapest first, with what the repo already has: a wire-level HTTP stub (e.g. MSW, `respx`, `responses`, recorded cassettes); a fake of an owned adapter around the library; a real DB (transactional fixture, in-memory, containers) only if that infra already runs in the suite. None available: report.
- **Keep when**: external systems you can't run (payment gateway, SMS); failure injection a real dependency can't produce (timeout, 500, disk full); `open`/`os.path` patches in tests that otherwise use real temp files; clocks and randomness (inject those instead).

### Same collaborator mocked separately in many files

- **Tell**: the same module or endpoint is mocked with a hand-written factory in 3+ test files (`grep -rhoE "jest\.mock\(['\"][^'\"]+" | sort | uniq -c | sort -rn`), usually spec-less, so a renamed method fails nowhere.
- **Do**: in this file, derive the mock from the real type (`create_autospec(Real, spec_set=True)`, `patch(..., autospec=True)`, a factory typed against the real module). Report the duplicates with a suggested single shared fixture or fake. A spec-less `Mock()` alone is not a finding; contract tools (Pact) only for multi-service setups.
- **Keep when**: one test needs a one-off pathological collaborator or malformed payload; a shared fake would have one user.

### Coverage padding and library tests

- **Tell**: restating declarations: `assert TIMEOUT == 30`, dataclass/pydantic defaults, enum members, attributes equal the args just passed, `isinstance`/`typeof`/`hasattr` on a declared type. Tests of someone else's code: the ORM persists, pydantic rejects a wrong type, library-generated messages (`value is not a valid integer`). Error tests for inputs the static types exclude on internal call paths. Weaker cousins on real SUT output: sole assertion `toBeDefined`/`toBeTruthy`/`is not None`/`len(x) > 0`; "renders without crashing" next to a behaviour test that renders the same component.
- **Do**: delete declaration and library tests. A weak sole assertion on real output exercises production code, so it is never deleted: strengthen it to the value the test name promises, or leave it when that value is unclear. If a config value encodes a real rule, rewrite to the invariant (`client_timeout < upstream_timeout`). For library behaviour your code depends on, test it through your behaviour (the endpoint rejects a bad payload with _your_ error code).
- **Keep when**: one app-boots smoke test, or a smoke render that is a component's only coverage; constants that are an external contract (protocol version, public limits); getters, `__repr__` or `toString` with logic; models with custom validators, computed fields or serializers, and library config that is the logic (security headers, auth rules); runtime checks on public entry points callable from untyped code (plain JS, Python without a type checker, FFI); regression tests for real bugs; a few named learning tests pinning a library quirk you rely on.

### Registry mirrors and counts

- **Tell**: on a module-level registry, enum or config collection: `toHaveLength(12)`, `len(COMMANDS) == 17`, `assert_eq!(x.len(), 9)`, `Object.keys(routes).sort()).toEqual([...])`, `sorted(REGISTRY) == [...]`, `set(FLAGS) == {...}`, "all 12 providers load". Adding any item breaks it.
- **Do**: rewrite to iterate the real registry and assert per-item invariants (each route has an auth policy, each command has help and a handler, names unique). Assert membership of the one item a test cares about, never the total. For exhaustiveness, use the type system (`assert_never`, `satisfies never`, non-wildcard `match`).
- **Keep when**: closed sets where the count is the spec (weekdays, HTTP methods); counts of the SUT's computed output (pagination, dedup, filtering); security tripwires where adding an item must be a reviewed decision (public unauthenticated routes, permission grants, CORS origins); a deliberate API-surface lock via a dedicated report tool, updated on purpose.

```python
# before
assert len(COMMANDS) == 17
# after
@pytest.mark.parametrize("name,cmd", COMMANDS.items())
def test_command_is_documented(name, cmd):
    assert cmd.help and callable(cmd.handler)
```

### Expected value computed like the code computes it

- **Tell**: arithmetic, string building or table lookups on the expected side that replicate SUT logic (`expected = price * (1 + TAX_RATE)`, `expect(label(k)).toBe(LABELS[k])`, URLs built from SUT constants); both sides call the same helper; `for`/`if` generating expected values.
- **Do**: rewrite with literal worked examples (`100 at 25% → 125`) in a table of input/output pairs. Property tests on invariants (round-trip, idempotence) only if the repo already uses a property-testing library.
- **Keep when**: symbolic identifiers (`err.code == ErrorCode.NOT_FOUND`, enum members); tunables the behaviour is relative to (`exceeds MAX_RETRIES → fails`); differential tests against an independent simpler reference; parametrized loops over literal data; shared constants used as inputs, not expected outputs.

### Overspecified assertions

- **Tell**: deep equality on a whole response or object literal of 5+ keys in a test named for one facet; `toThrow('<full sentence>')`, `str(e) == ...`, `match='<long sentence>'`; equality on `caplog.text`, console spies or stdout outside CLI-output tests; `JSON.stringify(a) === JSON.stringify(b)`, `repr`/`toString` comparisons; ordered list equality where the SUT doesn't sort; float equality without tolerance.
- **Do**: rewrite to the facet under test with the framework's partial matchers (`toMatchObject`/`expect.objectContaining`, a dict subset check, `hasEntry`, field-ignoring comparison); error type or code, or a short regex on the key token; structured log fields; unordered comparison; `approx`/`toBeCloseTo`.
- **Keep when**: absence of extra fields is the point (no `password_hash` or token leaks, public API shape): assert the exact key set in one dedicated test; wire-format/serialization contracts; user-facing error text that is itself a requirement (one central test); log lines others parse (audit trail, alert rules); small value objects; CLI output consumed by scripts; compiler/parser diagnostics.

### Broad or unstable snapshots

- **Tell**: `toMatchSnapshot`/`toMatchInlineSnapshot`/`assert_snapshot!`/golden files as the only assertion, on `container`/`asFragment()`/whole pages or full responses; `.snap`/`.golden`/`.approved.*` entries over ~50 lines; snapshot content with timestamps, UUIDs, `/home/` paths, `css-[a-z0-9]{5,}` hashes, ports.
- **Do**: rewrite to explicit assertions on what the test is named for. A generic name ("renders correctly"): assert the content and states the component derives from its props; leave static markup unasserted. If a snapshot stays, shrink it to the relevant node, scrub volatile fields (property matchers like `expect.any(Date)`, serializers, redaction), inject clocks and seeds, and name it after its intent. Delete orphaned snapshot entries with the test.
- **Keep when**: the exact output is the product (compiler, codegen, formatter, linter diagnostics, serializer, migrations, CLI help); characterization tests pinning legacy behaviour before a refactor. Even then: small, scrubbed, one concern each.

```tsx
// before
expect(render(<Cart items={items} />).container).toMatchSnapshot();
// after
render(<Cart items={items} />);
expect(screen.getByRole("listitem", { name: /mug/i })).toBeInTheDocument();
expect(screen.getByTestId("cart-total")).toHaveTextContent("€24.00");
```

### UI tests pinned to markup, copy or styling

- **Tell**: structural selectors: class chains and utility classes (`.bg-`, `.flex`), XPath, `nth-child`/`>> nth=`/`.eq(N)`/`children[N]`/`firstChild`, generated hashes (`css-…`, `sc-…`, `jss12`, `#react-select-3`). Verbatim long copy (5+ words, toasts, body text) asserted with `toHaveText`/`toContainText`/`cy.contains` in specs about something else. `toHaveCSS`/`toHaveStyle`/`toHaveClass('bg-…')`, screenshots inside functional specs. Flow tests asserting every detail of every screen.
- **Do**: rewrite. Locate by role + accessible name, label, then `data-testid` when nothing user-facing is stable; narrow with `filter({ hasText })`, not paths. Assert the outcome (order created, redirected, row visible). For churning copy, match a stable fragment regex or the i18n key. Leave visual checks to a visual-regression suite.
- **Keep when**: role + short accessible name (`getByRole('button', { name: 'Save' })`) is the recommended locator and an a11y contract; `data-testid` selectors; legal, pricing or safety copy that must be verbatim (one test each); intermediate assertions that wait for a screen before the next action (rewrite their locator, keep the wait); canvas/SVG with no accessible handle; a markup or component library testing its own DOM or published class names.

### Tests coupled to code structure

- **Tell**: visibility widened only for tests (exports marked "for testing", `__test__`/`testOnly` exports, `@VisibleForTesting`, `setAccessible(true)`, `pub(crate)` used only by tests, `friend class FooTest`); state inspection (`obj._cache`, `wrapper.state()`, `.instance()`); shallow rendering asserting props passed to children, mocked child components; test names describing mechanics ("calls fetchUser then sets state").
- **Do**: rewrite through the public entry point (for UI: what the user sees and does) and name by behaviour ("rejects expired tokens"). Route test-only exports to `structure.md` (`route structure`). If a private algorithm deserves direct tests, report extracting it into a module with its own contract.
- **Keep when**: Rust in-module `#[cfg(test)]` and Go same-package tests of private items (idiomatic); pure utility functions where each is the behaviour; complex algorithms whose edge cases the outer API can't reach; temporary characterization tests during a refactor. Co-located or one-file-per-module test layout alone is not a finding.

### Hand-built test data

- **Tell**: a type or payload built by hand with every field (`User(id=1, name=…, email=…, role=…, created_at=…)`, large object literals, inline API responses, near-duplicate JSON fixtures) in a test that asserts one or two fields; the same 5+-field shape in ~5+ tests (`grep -rcE 'User\(' tests/`). Adding a required field edits all of them.
- **Do**: if a builder or factory exists, rewrite to it, overriding only the fields the test depends on. If the copies are all in this file, a local `make_user(**overrides)` is fine. Otherwise report the sites and suggest one builder per type with deterministic defaults (no random fakers), typed against the real schema. Values the assertion depends on are set explicitly in the test, never inherited from a default.
- **Keep when**: two or three uses; the full payload is the point (parsing a recorded response, serialization contract).

### Shared mega-fixtures and mystery guests

- **Tell**: tests depending on values defined elsewhere (`user 42` from `seed.sql`, `fixtures/users.json`, a root `conftest` fixture used for one field); outer `beforeEach` assigning `let` variables that nested `describe`s reassign; results differing when run alone vs in the suite.
- **Do**: in this file, make the values the assertion depends on visible in the test body, and replace mutable nested setup with a per-test setup function returning fresh data. Report an oversized shared fixture with its few real users.
- **Keep when**: expensive read-only resources (schema, compiled corpus, browser auth state); centralized login; read-only reference data that is itself versioned config.

### Same behaviour asserted many times

- **Tell**: copy-pasted tests differing only by one value (`test_status_active`, `test_status_inactive`) instead of a table; the same edge case (`'a@'`, "invalid email") enumerated in unit, integration and e2e layers; e2e specs walking every invalid-input permutation.
- **Do**: collapse variants into one parametrized or table test with a readable id per row. Upper-layer permutations still exercise production code, so don't delete them: grep for a lower-layer test asserting the same rule and, if found, report them with that test and keep-one-representative (it proves wiring) as the suggested shape. Line-coverage overlap alone is not redundancy: require identical assertions.
- **Keep when**: defense in depth on money, auth or safety paths; risks a lower layer can't see (serialization, middleware order, browser behaviour); variants whose setups genuinely diverge.

### Over-abstracted test helpers

- **Tell**: helpers branching on flags (`if opts.withAdmin`); a test body that is one `runScenario(config)` call with no visible assertion; `assertValidUser` checking 15 unrelated fields; test utils re-wrapping production internals. This is the overcorrection; don't create it while fixing the entries above.
- **Do**: helpers build data; the act and the assertions stay in the test. Inline a helper in this file that hides the act or the assertions and serves one or two tests; report flag-heavy shared helpers with a suggested split.
- **Keep when**: table-driven tests where each row shows inputs and expected output, even through a shared `runCase(row)`; stable mechanics (start server, log in, wrap a transaction); a domain assertion with one meaning (`assertMoneyEquals`).

### Time-dependent tests and bumped timeouts

- **Tell**: hardcoded dates or ages that expire (`birth_year=1990; assert age == 36`, "expires 2026-12-31"); `datetime.now()`/`Date.now()` without a clock fake; `sleep(`/`waitForTimeout`/`setTimeout(... resolve` waits; timeouts raised or retries added (`@flaky`, `jest.retryTimes`) by changes unrelated to the test.
- **Do**: rewrite: freeze or inject the clock with the repo's existing tool (framework fake timers, a clock parameter the SUT already takes) and derive dates from it; replace sleeps with condition waits (web-first `expect`, `waitFor`, polling). If the SUT reads the wall clock with no seam, report. Never fix a flake by raising a number.
- **Keep when**: timing-contract tests (debounce, rate limit, timeout behaviour), though they should still use fake time; soak/load tests where variance is the point; a temporary retry on a tracked flake with an issue link.

## Sources

- Software Engineering at Google, ch. 12 "Unit Testing" and ch. 13 "Test Doubles": https://abseil.io/resources/swe-book/html/ch12.html, https://abseil.io/resources/swe-book/html/ch13.html
- Google Testing Blog, "Change-Detector Tests Considered Harmful" and "Don't Mock Types You Don't Own": https://testing.googleblog.com/2015/01/testing-on-toilet-change-detector-tests.html, https://testing.googleblog.com/2020/07/testing-on-toilet-dont-mock-types-you.html
- Vladimir Khorikov, "When to Mock": https://enterprisecraftsmanship.com/posts/when-to-mock/
- Gerard Meszaros, xUnit Test Patterns: Fragile Test, Sensitive Equality, General Fixture: http://xunitpatterns.com/Fragile%20Test.html
- Kent C. Dodds, "Effective Snapshot Testing": https://kentcdodds.com/blog/effective-snapshot-testing
- Testing Library guiding principles and Playwright best practices: https://testing-library.com/docs/guiding-principles, https://playwright.dev/docs/best-practices
- Nat Pryce, "Test Data Builders": http://natpryce.com/articles/000714.html
- Hora & Robbes, "Are Coding Agents Generating Over-Mocked Tests?" (MSR 2026): https://arxiv.org/abs/2602.00409
