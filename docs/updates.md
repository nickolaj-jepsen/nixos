# Nightly updates

One PR a day, automerged, and a broken update never blocks the others. All of
it is `.github/scripts/update_bot.py`, driven by the workflows named below.

## Flow

1. **`update.yml`** runs on a nightly cron, kept off the hour so GitHub
   doesn't delay it by hours.
   - It resets `auto/update` from `main` and runs `nix flake update`. If that
     fails it updates input by input, holding back inputs that can't be
     fetched.
   - It runs the cache gate (below) and `update_packages.py`, formats, and
     force-pushes one commit.
   - The single PR on that branch is created or refreshed, and auto-merge
     (rebase) is enabled.
   - `CI gate` is the only thing that has to pass.
2. **`update-triage.yml`** runs when CI fails on `auto/update`.
   - It takes the root failed derivations from the failed jobs' logs:
     `Cannot build … builder failed`, plus the
     `update-triage: timeout-inflight` markers that `ci-build.sh` prints when
     its step timeout hits.
   - For each updated _unit_ (a root flake input, or `pkgs/<name>`), it
     reverts only that unit in a worktree and re-evaluates.
   - A unit is the culprit when reverting it makes the failed `.drv` drop out
     of the host's closure, or makes a failed eval succeed.
   - It only evaluates and never builds, so triage takes a few minutes in
     total.
   - It reverts the culprits, amends the commit and force-pushes. Flake inputs
     are grafted back from `main`'s lock, and packages are checked out from
     `main`. CI re-runs and the rest automerges.
   - `MAX_TRIAGE_PASSES` caps the passes per day.
   - If nothing is attributable, it re-runs the failed jobs once, then
     comments on the status issue with an @-mention.
3. When the PR merges, the `landed` job clears state for every unit that wasn't
   held back and closes its issue.

## Held-back state and escalation

- State lives in the pinned **Update status** issue (label `update-status`): a
  table plus a JSON blob the bot rewrites. Don't edit it by hand.
- A unit held back for its kind's number of consecutive nights (`THRESHOLDS`
  in `update_bot.py`) escalates to an `Update held back: <unit>` issue plus
  the fix agent.
- Kinds in `UNFIXABLE_KINDS` (missing caches, unreachable upstreams) get a
  `needs-human` issue and no agent.
- Timeouts mean something big wasn't in any cache, so code can't fix them.

## Cache gate

- `CACHE_GATED` in `update_bot.py` maps an input to a package and the binary
  cache that has to serve it. Example: `nixpkgs-cuda` to `llama-cpp-cuda` on
  cache.nixos-cuda.org, which can trail `nixos-unstable` by a day.
- After updating, the bot evaluates the package. If the cache has no narinfo
  for it, the input goes back to `main`'s lock as a `cache` hold, instead of
  CI compiling CUDA until the step timeout.
- The hold clears itself the night the cache catches up.
- Reaching the escalation threshold usually means the package no longer
  matches the cache's build (an override in `pkgs/llama-cpp-cuda`). The issue
  exists for that case.

## npm cooldown

- `pi-coding-agent` and `pi-packages` only move to an npm release published at
  least three days earlier (`npm_cooled` in `update_packages.py`).
- The pi-packages lock is regenerated with `npm --before` at the same cutoff,
  so new transitive deps wait too.
- A broken or hijacked release is usually pulled within that window, and these
  bumps still automerge.

## Fix agent (`update-fix.yml`)

It is dispatched once per failure signature (unit + kind + failed drv names).
It applies the held-back update as a `chore(update): bump <unit>` commit, then
Claude (`claude-code-action`, `CLAUDE_CODE_OAUTH_TOKEN`) returns a verdict:

- `fix-pr`: a minimal fix on `auto/fix-<unit>`, in a PR referencing the issue.
  Merging it lands the bump too, so `landed` clears the unit and closes the
  issue.
- `upstream`: cites the upstream issue and opens no PR. The issue closes when
  the update lands.
- `needs-human`: explains, and @-mentions the owner.

Limits, and how its changes reach a branch:

- Workaround pins, `enable = false` and `allowBroken` are off-limits: holding
  an update back is already the bot's job.
- The agent can run anything in its job (`nix run`), so that job holds no push
  token and nothing from it is trusted.
- It hands its verdict and its changes (a `git diff`) to a second job,
  `publish`, as data.
- `publish` runs on a fresh runner and a checkout of the commit the agent
  started from. It redoes the bump, applies the diff with `git apply` and runs
  nothing from the patched tree.
- It pushes only if every changed path is under `FIX_ALLOWED`
  (`update_bot.py`), because CI runs a branch's scripts and flake inputs with
  secrets before any review.
- Anything else, e.g. a fix to `update_packages.py`, goes on the issue as a
  diff, as `needs-human`.

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
  do, which is why the fix agent is started with `gh workflow run`, not a
  label.

## Local use

- `just update [input]` runs `nix flake update` and then the cache gate
  (`update_bot.py cache-gate`, against `HEAD`'s lock), so a local switch
  doesn't compile CUDA either.
- `just update-packages [name…]` runs the `pkgs/` updaters.
- From a checkout of `auto/update`, this prints the attribution without
  pushing or writing to GitHub:

  ```bash
  GITHUB_TOKEN=$(gh auth token) GITHUB_REPOSITORY=nickolaj-jepsen/nixos \
    python3 .github/scripts/update_bot.py triage --run-id <id> --dry-run
  ```
