# Janitor

Agents and dev tools leave things behind, and none of them owns the cleanup.
Claude Code gives every session a scratch directory under `TMPDIR` and removes
none of them; `/tmp` on this machine reached 44 GB of 47 GB that way, most of it
one afternoon's downloads. Around that sit the leftovers with no owner at all:
finished job directories, transcripts nothing reads any more, branches merged
months ago, worktrees nothing landed in, and build directories in repos nobody
has opened since spring.

The janitor owns those, in two passes with very different appetites.

## The pieces

| Piece                          | What it does                                                                            |
| ------------------------------ | --------------------------------------------------------------------------------------- |
| `pkgs/janitor`                 | The CLI: `report`, `plan`, `apply`, `run tmp\|repo`, `dir`, `state`, `warn`, `warnline` |
| `modules/programs/janitor.nix` | Puts it on `PATH`, runs the two timers                                                  |
| The agent wrappers             | `claude`, `claude-work` and `pi` export `TMPDIR=/tmp/agent/<pid>`                       |
| `modules/desktop/dms/janitor`  | The bar pill in the storage slot, and the popout checklist                              |
| pi's `janitor` extension       | One appended tool-result line under disk pressure                                       |
| Claude's `PreToolUse` hook     | The same line, for Claude Code                                                          |

All of it is behind `fireproof.janitor.enable`, which cascades from
`dev.enable`.

## What each rule deletes

| Rule                | When it goes                                                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Agent temp          | The dir is named after its wrapper's pid and `/proc/<pid>` is gone; or, for legacy `/tmp/claude-1000` paths, the session registry no longer knows it and it has been idle an hour     |
| Claude Code job tmp | The job directory has been untouched for 7 days                                                                                                                                       |
| `/tmp` strays       | `pi-*`, `oc`, `opencode`, `jiti`, `node-compile-cache` past 3 days                                                                                                                    |
| Transcripts         | A `.jsonl` older than 30 days. `memory/` and `MEMORY.md` are siblings and never match                                                                                                 |
| Merged branches     | Every commit is reachable from the default branch, and no worktree has it checked out                                                                                                 |
| Worktrees           | `wt clean` decides: clean tree, landed, not busy, not locked                                                                                                                          |
| Build dirs          | `node_modules`, `.venv`, `target`, `dist`, `.pytest_cache`, `__pycache__` in a repo with no commit in 60 days, no process whose cwd is inside it, and a directory untouched that long |
| Unmerged branches   | Only in `apply`, only when ticked, and bundled first                                                                                                                                  |
| Stale scratch       | Only in `apply`, only when ticked: a `~/scratch` entry nothing inside has touched for 30 days                                                                                         |

Strays, the top-level entries of `~` outside the home layout
(docs/home-layout.md), are listed in `report` and the popout with a suggested
destination, and never deleted.

A _live_ temp session is never touched: the budget cannot reach it, so the only
lever there is the warning line, and the agent has to give the space back itself.
Nothing outside the named build directories is ever deleted from a working tree —
`reverse/engagements` is 22 GB of engagement data and `devenv-tilt/projects` is
19 GB of VM state, and an "untouched repo" rule would have been aimed at both.

## The two timers

`janitor-tmp` runs every 15 minutes and at login. It reaps dead temp dirs,
finished job directories and strays, and enforces the 16 GB budget and the 10 %
free floor by evicting dead sessions oldest-first.

`janitor-repo` runs at 04:00 with `Persistent=true`, and five minutes after
login. It deletes merged branches, runs `wt clean` in every repo that has
something to clean, drops transcripts past their month, then recomputes the
cached plan the widget reads.

Under 10 % free the tmp pass still runs and still shouts — journal, toast, red
pill. It does not reach into working trees for build directories; that is always
`just janitor apply`.

```bash
just janitor              # what is here and what a pass would free; deletes nothing
just janitor plan         # the same as JSON
just janitor apply        # the checklist: space toggles, enter applies
just janitor run repo     # what the daily timer does (run tmp for the other one)
journalctl --user -u janitor-repo   # what it actually did
```

`apply` is a terminal checklist for the same rows the popout shows, one row per
item: build directories and dead temp start ticked, branches do not. A branch is
the one row whose loss is not merely a rebuild, so it takes a deliberate tick and
is bundled first, to
`~/.local/state/janitor/bundles/<repo>/<branch with / written as %>.bundle`, then
deleted. Restore one with `git fetch <bundle> <branch>:<branch>`.

An id is not a licence: every row is re-checked when it is applied, against the
rules as they stand at that moment, because the checklist can be an hour old and
`apply --ids` accepts ids from anyone. A transcript must still be a `.jsonl`
under a `projects` directory, a build directory must still be one of the named
ones inside a repo in the roster with nothing running in it, and a temp path must
still fail the liveness test right then.

## The widget

The pill replaces the storage widget in the bar: same `storage` icon, same
percentage, same colour at 75 % and 90 %, with what the janitor could reclaim
beside it. It reads only cached numbers, so a bar render never walks the disk.
Opening it runs `janitor plan` (once an hour at most) and turns the popout into
the checklist — ticking rows and pressing Apply runs `janitor apply --ids`, so
the bar can do the whole job without a terminal.

## Knobs

Constants in `modules/programs/janitor.nix`'s CLI, overridable by environment
variable for tests: `JANITOR_TMP_BUDGET_GIB` (16), `JANITOR_TMP_MAX_AGE_DAYS`
(3), `JANITOR_FREE_FLOOR_PCT` (10), `JANITOR_WARN_FREE_GIB` (10),
`JANITOR_TRANSCRIPT_AGE_DAYS` (30), `JANITOR_JOB_TMP_AGE_DAYS` (7),
`JANITOR_BUILD_DIR_AGE_DAYS` (60), `JANITOR_BRANCH_IDLE_DAYS` (90),
`JANITOR_SCRATCH_AGE_DAYS` (30). The repo roster, scratch and the declared roots
come from `~/.config/janitor/layout.json` (`JANITOR_LAYOUT`), which the leaf
writes from `fireproof.paths`. The roots and the roster are `JANITOR_ROOT`,
`JANITOR_LEGACY_ROOT`, `JANITOR_STALE_PATHS`, `JANITOR_REPO_PARENTS`,
`JANITOR_REPO_SINGLES`, `JANITOR_SCRATCH`, `JANITOR_HOME_ROOTS`,
`JANITOR_STATE_DIR`; the fixture-only ones exist so a test can point the walk at
a temp tree.

## Traps

- **A detached background job outlives the pid that named its temp dir.** Once
  the session process is gone, so is its `TMPDIR`, whatever still holds a path
  into it. `bg_run`-style jobs have to finish inside their session.
- **`sudo` resets `TMPDIR`,** so root-run commands inside an agent still use
  `/tmp`. That is why the legacy paths stay in the walk.
- **A recycled pid looks live.** The three-day rule is what eventually reaps it.
- **There is no filesystem cap.** btrfs quotas are off, and turning them on for
  one 20 GB limit costs a filesystem-wide rescan on five hosts; the budget plus
  the warning line is what exists instead.
- **Transcripts feed pi-auto-gate's `extract`,** which rebuilds the judge dataset
  from every `.jsonl` under `~/.claude/projects` and `~/.claude-work/projects`.
  Their 30-day age is the window in which a re-run of `extract` can still see
  them.
- **The sandbox's qcow2 images are not touched.** That is
  `~/.local/state/pi-auto-sandbox/disks`, outside every root here: `pi-auto-gate`
  has its own `collectGarbage` and knows which disk is a template. What the stray
  rule does reach is `/tmp/pi-*`, which is temp space like any other.
- **`wt clean` deletes what it deletes.** The janitor only decides _when_ to run
  it, never what a worktree is worth.
