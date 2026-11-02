# Analysis tools

Run the rows that answer a question you still have, not all of them. Reading the code and what wires it in usually earns more than tool output.

- **Getting them:** use a local binary, else `nix run nixpkgs#<attr> -- <args>`. Attributes can differ from tool names (`python3Packages.vulture`). `uvx` and `pnpm dlx` fetch and run third-party packages, so they wait for the approved plan; import-linter, deptry, jscpd, knip and dependency-cruiser needed them at last check.
- **Trust:** check `--help` before relying on a flag, because versions differ. If a tool is unavailable, skip it and say so.
- **Writing:** anything that writes config or output belongs in the clone, never the user's checkout. Before there's a clone, send output to stdout and skip the rows that need config.
- **Size:** for a target under about 20 files, `git ls-files <path>` and `wc -l` are enough. Skip import-graph and layer tools when it has one module.

## History shape comes first

With a subsystem, add `-- <path>` to every git command here. Running from a subdirectory doesn't limit them.

```bash
git log --oneline | wc -l
git shortlog -sn --no-merges HEAD   # HEAD is required: without it, a non-terminal stdin prints nothing
git log --format='@%h %s' --name-only | awk '/^@/{c=$0;next} NF{n[c]++} END{for(k in n)print n[k],k}' | sort -nr | head   # largest commits
```

History carries no signal if a few commits touch most of the files, or if the target has only a few commits or a short history. Then skip churn, blame, ownership and coupling, or restrict them to the period after the initial dump. Empty results can come from thresholds rather than the code, so don't read them as "no coupling". Exclude bots with `--perl-regexp --author='^(?!.*\[bot\])'`. A hotspot says where to read first, not that the code is bad.

## By question

| Question                             | Tool                                                                                                                                           | Watch for                                                                        |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| How big, what shape, how branchy?    | `tree --gitignore -L 2`; `git ls-files \| cut -d/ -f1-2 \| sort \| uniq -c \| sort -nr \| head`; `scc --by-file -s complexity --no-cocomo src` | Complexity is a token-based estimate; rank within a repo only                    |
| Which files change most?             | `git log --format=format: --name-only --since="1 year ago" -- <path> \| grep -v '^$' \| sort \| uniq -c \| sort -nr \| head -20`               | Needs usable history; lockfiles and changelogs dominate raw churn                |
| Where do change and complexity meet? | `scc --hotspots src`, `scc --coupling` (scc 4.x; older versions reject them, so check `scc --version` first)                                   | Needs usable history                                                             |
| Where do fixes land?                 | `git log -i -E --grep="fix\|bug\|broken" --name-only --format='' -- <path> \| grep -v '^$' \| sort \| uniq -c \| sort -nr \| head -20`         | Depends on honest commit messages                                                |
| Python structure                     | `pydeps src/pkg --show-cycles --no-output --show-deps` (without `--no-output` it writes an image); `import-linter explore`                     | Large graphs; narrow with `--only` and `--max-bacon`                             |
| JS/TS structure                      | `depcruise src --include-only "^src" -T dot`; also `-T mermaid`, `--focus`, `--reaches`                                                        | Run `depcruise --init` in the clone first; unconfigured runs can come back empty |
| Do my believed layers hold?          | An `import-linter` layers contract, or a dependency-cruiser forbidden rule, written in the clone                                               | Failures are the finding, so report them rather than fixing them                 |
| What is dead?                        | `knip --production`; `vulture src --min-confidence 80`; `deptry .`                                                                             | Frameworks, public APIs and reflection give false positives                      |
| What was pasted around?              | `jscpd src --min-tokens 50`                                                                                                                    | Textual clones only, not re-implementations under new names                      |
| Every place shaped like X            | `ast-grep run -p 'isinstance($A, $B)' -l python src`                                                                                           | Syntax only: no types or data flow                                               |
| Who reaches this symbol?             | Call the agent's LSP tool directly; agents rarely choose it on their own                                                                       | Under-reports through DI and decorators                                          |
| Data flow across files               | Joern                                                                                                                                          | Slow to set up; use for a specific question                                      |

Prefer import graphs to static call graphs in Python and TS, because dynamic dispatch and decorators defeat the latter.

## At runtime

| Question                      | Tool                                                                    |
| ----------------------------- | ----------------------------------------------------------------------- |
| One flow, step by step        | The language's debugger                                                 |
| Function timeline in Python   | `viztracer`; `py-spy dump --pid <pid>` for what a live process is doing |
| Spans across HTTP, DB, queues | OpenTelemetry zero-code instrumentation with `otel-tui`                 |
| The real external contract    | `mitmproxy`, against local or dummy endpoints                           |
| The actual schema             | `tbls`, or the database's own catalog                                   |

A trace shows one execution, so unreachable paths, error handling and invariants still need reading.

## Traps

- `nixpkgs#hercules` is a mainframe emulator, not the git tool, which is abandoned anyway.
- The live Sourcetrail fork covers only C/C++ and Java, and `stack-graphs` is archived.
- `madge` reports type-only import cycles that have no runtime effect.
- The CodeQL CLI licence prohibits private code without a paid licence.
- `uvx` may pick a Python too new for a tool; pass `--python` with an older version if it crashes on start.
