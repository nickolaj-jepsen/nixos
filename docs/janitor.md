# Janitor

Agents and dev tools leave things behind, and none of them owns the cleanup.
The janitor does, in a cheap frequent pass over temp space and a daily pass over
repos.

- Claude Code gives every session a scratch directory under `TMPDIR` and
  removes none of them; `/tmp` on this machine reached 44 GB of 47 GB that way.
- Around that sit leftovers with no owner: finished job directories, branches
  merged months ago, worktrees nothing landed in, and build directories in
  repos nobody has opened since spring.
- Everything here is behind `fireproof.janitor.enable`, which cascades from
  `dev.enable`.
- The CLI is `pkgs/janitor`, and its subcommands are listed at the top of
  `pkgs/janitor/head.sh`. `modules/programs/janitor.nix` puts it on `PATH` and
  runs the timers.
- The `claude`, `claude-work` and `pi` wrappers export
  `TMPDIR=/tmp/agent/<pid>` (from `janitor dir`), the root the tmp pass sweeps.

## What each rule deletes

- Agent temp: the dir is named after its wrapper's pid and `/proc/<pid>` is
  gone. A legacy `/tmp/claude-1000` path goes once the session registry no
  longer knows it and it has been idle an hour.
- Claude Code job tmp: the job directory has been untouched for 7 days.
- `/tmp` strays: `pi-*`, `jiti` and `node-compile-cache` past 3 days.
- Merged branches: every commit is reachable from the default branch, and no
  worktree has it checked out.
- Worktrees: `wt clean` decides (clean tree, landed, not busy, not locked, not
  new).
- Build dirs: `node_modules`, `.venv`, `target`, `dist`, `.pytest_cache` and
  `__pycache__`, in a repo with no commit in 60 days, with no process whose cwd
  is inside it, and the directory itself untouched that long.
- Nix roots in `/tmp`: an out-link outside the agent temp roots, untouched for
  3 days.
- Nix roots in repos, only in `apply`: a `result*` link untouched for 7 days,
  or the `.direnv` links of a repo idle the way the build-dir rule means it.
- Unmerged branches, only in `apply`: idle 90 days, only when ticked, and
  bundled first.

Limits:

- A live temp session is never touched; the budget can't reach it. The only
  lever there is the warning line, and the agent has to give the space back
  itself.
- Nothing in a working tree is deleted except the named build directories and
  those nix links. `reverse/engagements` (22 GB of engagement data) and
  `devenv-tilt/projects` (19 GB of VM state) are what an "untouched repo" rule
  would have hit.

## Timers

Both are systemd user units, Linux only.

- `janitor-tmp` runs every 15 minutes and at login. It reaps dead temp dirs,
  finished job directories and strays, then enforces the 16 GB budget and the
  10 % free floor by evicting dead sessions oldest-first.
- `janitor-repo` runs at 04:00 with `Persistent=true`, and five minutes after
  login. It deletes merged branches, runs `wt clean` in every repo that has
  something to clean, drops stale `/tmp` out-links, then recomputes the cached
  plan the widget reads.
- The weekly nix GC collects what those links held. `apply` runs
  `nix-store --gc` itself once it has removed a root, so the checklist shows the
  space straight away.
- Under 10 % free the tmp pass still runs and shouts (journal, toast, red
  pill), but it never reaches into working trees for build directories. That is
  always `just janitor apply`.

```bash
just janitor              # what is here and what a pass would free; deletes nothing
just janitor plan         # the same as JSON
just janitor apply        # the checklist: space toggles, enter applies
just janitor run repo     # what the daily timer does (run tmp for the other one)
journalctl --user -u janitor-repo   # what it actually did
```

## The checklist

- `apply` is a terminal checklist of the same rows the popout shows, one row
  per item. Build directories and dead temp start ticked; branches don't.
- A branch is the one row whose loss is more than a rebuild, so it takes a
  deliberate tick. It is bundled to
  `~/.local/state/janitor/bundles/<repo>/<branch with / written as %>.bundle`,
  then deleted.
- Restore a branch with `git fetch <bundle> <branch>:<branch>`.
- Every row is re-checked against the current rules when it is applied: the
  checklist can be an hour old and `apply --ids` accepts ids from anyone. A
  build directory must still be a named one inside a repo in the roster with
  nothing running in it, and a temp path must still fail the liveness test.

## Warning line

- Under 10 GiB free, agents get one line about disk pressure, at most once per
  ten minutes per session.
- Claude Code gets it from a `PreToolUse` hook on Bash (`janitor warn`). pi's
  `janitor` extension appends it to a tool result (`janitor warnline`).

## The widget

- `modules/desktop/dms/janitor` replaces the storage widget in the bar: same
  `storage` icon, same percentage, same colour at 75 % and 90 %, with what the
  janitor could reclaim beside it.
- The pill reads only cached numbers (`janitor state`, written by the timers),
  so a bar render never walks the disk.
- Opening it runs `janitor plan` (once an hour at most) and turns the popout
  into the checklist. Ticking rows and pressing Apply runs
  `janitor apply --ids`, so the bar can do the whole job without a terminal.

## Knobs

- The thresholds, roots and repo roster are constants at the top of
  `pkgs/janitor/head.sh`, each overridable by a `JANITOR_*` environment variable
  for tests.
- The root, legacy-root, stray-path, roster and state-dir variables exist so
  a test can point the walk at a temp tree.

## Traps

- A detached background job outlives the pid that named its temp dir. Once the
  session process is gone, so is its `TMPDIR`, whatever still holds a path into
  it. `bg_run`-style jobs have to finish inside their session.
- `sudo` resets `TMPDIR`, so root-run commands inside an agent still use
  `/tmp`. That is why the legacy paths stay in the walk.
- A recycled pid looks live. The three-day rule eventually reaps it.
- There is no filesystem cap. btrfs quotas are off, and turning them on for one
  20 GB limit costs a filesystem-wide rescan on five hosts; the budget plus the
  warning line stand in for it.
- Transcripts are never touched. pi-auto-gate's `extract` and `/mine` read the
  whole history under `~/.claude*/projects`.
  - About nine tenths of the bytes are subagent transcripts, but `/home` is
    btrfs with `compress=zstd:3`, so they already sit compressed on disk.
    Compressing or pruning them here was measured to free a small fraction of
    the apparent size.
  - Revisit only under real disk pressure, and even then never touch a
    workflow's `journal.jsonl`: Claude Code reads it to resume the run.
- The sandbox's qcow2 images are not touched: they live in
  `~/.local/state/pi-auto-sandbox/disks`, outside every root here.
  `pi-auto-gate` has its own `collectGarbage` and knows which disk is a
  template. The stray rule does reach `/tmp/pi-*`, which is ordinary temp
  space.
- Nix roots are found through the daemon (`nix-store --gc --print-roots`), not
  a walk, so an out-link at any depth is seen.
  - A row's size counts only store paths nothing else rooted reaches, so rows
    add up. It is NAR size, and `nix.optimise`'s hard links can make the real
    gain smaller.
  - Roots outside `/tmp` and the repo roster, such as `~/.local/share/agents/*`
    builds, are never touched.
- `wt clean` deletes what it deletes. The janitor only decides _when_ to run
  it, never what a worktree is worth.
- Busy means a process's cwd is inside. Subagents and editors that reach a
  worktree by path don't count, so `wt` instead keeps a branch nothing has
  committed to for a day.
- A swept worktree takes its gitignored files with it. Untracked files keep a
  worktree; ignored ones (`.env`, local databases, output under an ignored
  path) don't, so anything worth keeping there needs a home outside the tree.
