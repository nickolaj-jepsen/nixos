# Nightly updates

One PR a day, automerged, and a broken update never blocks the others. All of
it is `.github/scripts/update_bot.py`, driven by the workflows named below.

## Flow

1. **`update.yml`** (nightly cron, kept off the hour so GitHub doesn't delay it by hours) resets `auto/update` from `main`, runs
   `nix flake update` (input by input if that fails, holding back inputs that
   can't be fetched), the cache gate (below) and `update_packages.py`, formats,
   and force-pushes one commit. The single PR on that branch is created or
   refreshed, and auto-merge (rebase) is enabled. `CI gate` is the only thing
   that has to pass.
2. **`update-triage.yml`** runs when CI fails on `auto/update`:
   - takes the root failed derivations from the failed jobs' logs (`Cannot
build … builder failed`, plus `update-triage: timeout-inflight` markers that
     `ci-build.sh` prints when its step timeout hits);
   - for each updated _unit_ (a root flake input, or `pkgs/<name>`), reverts
     only that unit in a worktree and re-evaluates. A unit is the culprit when
     reverting it makes the failed `.drv` drop out of the host's closure (or
     makes a failed eval succeed). Only evals, no builds: a few minutes in total;
   - reverts the culprits (flake inputs are grafted back from `main`'s lock,
     packages checked out from `main`), amends the commit, force-pushes. CI
     re-runs and the rest automerges. Passes per day are capped by
     `MAX_TRIAGE_PASSES`;
   - nothing attributable: re-runs the failed jobs once, then comments on the
     status issue with an @-mention.
3. When the PR merges, the `landed` job clears state for every unit that wasn't
   held back and closes its issue.

## Held-back state and escalation

State lives in the pinned **Update status** issue (label `update-status`): a
table plus a JSON blob the bot rewrites. Don't edit it by hand.

A unit held back for its kind's number of consecutive nights (`THRESHOLDS` in
`update_bot.py`) escalates to an `Update held back: <unit>` issue plus the fix
agent. Kinds in `UNFIXABLE_KINDS` (missing caches, unreachable upstreams) get
a `needs-human` issue and no agent. Timeouts mean something big wasn't in any
cache, so they aren't something code can fix.

## Cache gate

`CACHE_GATED` in `update_bot.py` maps an input to a package and the binary
cache that has to serve it, e.g. `nixpkgs-cuda` to `llama-cpp-cuda` on
cache.nixos-cuda.org, which can trail `nixos-unstable` by a day. After
updating, the bot evaluates the package; if the cache has no narinfo for it, the
input goes back to `main`'s lock as a `cache` hold instead of CI compiling CUDA
until the step timeout. The hold clears itself the night the cache catches up.
Reaching the escalation threshold usually means the package no longer matches
the cache's build (an override in `pkgs/llama-cpp-cuda`), which is what the
issue is for.

## Fix agent (`update-fix.yml`)

Dispatched once per failure signature (unit + kind + failed drv names). It
applies the held-back update as a `chore(update): bump <unit>` commit, then
Claude (`claude-code-action`, `CLAUDE_CODE_OAUTH_TOKEN`) returns a verdict:

- `fix-pr`: a minimal fix on `auto/fix-<unit>`, PR referencing the issue;
  merging it lands the bump too, so `landed` clears the unit and closes the issue;
- `upstream`: cites the upstream issue, no PR; the issue closes when it lands;
- `needs-human`: explains, @-mentions the owner.

Workaround pins, `enable = false` and `allowBroken` are off-limits: holding an
update back is already the bot's job.

The agent can run anything in its job (`nix run`), so that job holds no push
token and nothing from it is trusted. It hands its verdict and its changes (a
`git diff`) to a second job, `publish`, as data. On a fresh runner and a
checkout of the commit the agent started from, `publish` redoes the bump,
applies the diff with `git apply` and runs nothing from the patched tree. It
pushes only if every changed path is under `FIX_ALLOWED` (`update_bot.py`); CI runs a
branch's scripts and flake inputs with secrets before any review. Anything else,
e.g. a fix to `update_packages.py`, goes on the issue as a diff, as `needs-human`.

## Fix review gate (`update-fix-review.yml`)

Auto-merge is enabled on an `auto/fix-*` PR only if both checks pass:

1. **Hard rules** (`update_bot.py fix-rules`, main's copy): an optional bump
   commit (flake.lock/pkgs only) plus one small fix commit. Its path, size and
   forbidden-pattern limits are the `FIX_*` constants in `update_bot.py`.
2. **Review agent**: a separate, read-only Claude run that approves only
   minimal, behavior-preserving fixes.

Otherwise the PR gets `needs-review` and an @-mention.

## Tokens and notifications

- `BOT_TOKEN` (fine-grained PAT; contents, pull-requests, issues write) pushes
  branches and creates the update/fix PRs. Events from `GITHUB_TOKEN` don't
  trigger CI.
- Issues and comments are posted with `GITHUB_TOKEN` (github-actions[bot]), so
  they show up in the owner's notifications. The owner's own PAT actions never
  do. That's why the fix agent is started with `gh workflow run`, not a label.

## Local use

- `just update [input]` runs `nix flake update` and then the cache gate
  (`update_bot.py cache-gate`, against `HEAD`'s lock), so a local switch
  doesn't compile CUDA either.
- `just update-packages [name…]` runs the `pkgs/` updaters.
- `GITHUB_TOKEN=$(gh auth token) GITHUB_REPOSITORY=nickolaj-jepsen/nixos
python3 .github/scripts/update_bot.py triage --run-id <id> --dry-run`, run
  from a checkout of `auto/update`, prints the attribution without pushing or
  writing to GitHub.
