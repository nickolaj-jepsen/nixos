# Nightly updates

One PR a day, automerged, and a broken update never blocks the others. All of
it is `.github/scripts/update_bot.py` driven by four workflows.

## Flow

1. **`update.yml`** (00:00 UTC) resets `auto/update` from `main`, runs
   `nix flake update` (input by input if that fails, holding back inputs that
   can't be fetched), the cache gate (below) and `update_packages.py`, formats,
   and force-pushes one commit. The single PR on that branch is created or
   refreshed, and auto-merge (rebase) is enabled. `CI gate` is the only thing
   that has to pass.
2. **`update-triage.yml`** runs when CI fails on `auto/update`:
   - takes the root failed derivations from the failed jobs' logs (`Cannot
build … builder failed`, plus `update-triage: timeout-inflight` markers that
     `ci-build.sh` prints when the 100 min step timeout hits);
   - for each updated _unit_ (a root flake input, or `pkgs/<name>`), reverts
     only that unit in a worktree and re-evaluates. A unit is the culprit when
     reverting it makes the failed `.drv` drop out of the host's closure (or
     makes a failed eval succeed). Only evals, no builds: a few minutes in total;
   - reverts the culprits (flake inputs are grafted back from `main`'s lock,
     packages checked out from `main`), amends the commit, force-pushes. CI
     re-runs and the rest automerges. Capped at 3 passes per day;
   - nothing attributable: re-runs the failed jobs once, then comments on the
     status issue with an @-mention.
3. When the PR merges, the `landed` job clears state for every unit that wasn't
   held back and closes its issue.

## Held-back state and escalation

State lives in the pinned **Update status** issue (label `update-status`): a
table plus a JSON blob the bot rewrites. Don't edit it by hand.

A unit held back on consecutive nights escalates:

| Reason    | Threshold | Then                                         |
| --------- | --------- | -------------------------------------------- |
| `build`   | 3 nights  | issue `Update held back: <unit>` + fix agent |
| `eval`    | 3 nights  | same                                         |
| `script`  | 3 nights  | same (a package updater failed)              |
| `timeout` | 7 nights  | issue labeled `needs-human` only; no agent   |
| `fetch`   | 7 nights  | same (an input could not be fetched)         |
| `cache`   | 7 nights  | same (the cache gate held the input back)    |

Timeouts mean something big wasn't in any cache, so they aren't something code
can fix.

## Cache gate

`CACHE_GATED` in `update_bot.py` maps an input to a package and the binary
cache that has to serve it: `nixpkgs-cuda` to `llama-cpp-cuda` on
cache.nixos-cuda.org, which can trail `nixos-unstable` by a day. After
updating, the bot evaluates the package; if the cache has no narinfo for it, the
input goes back to `main`'s lock as a `cache` hold instead of CI compiling CUDA
for 100 minutes. The hold clears itself the night the cache catches up. Seven
nights in a row usually means the package no longer matches the cache's build
(an override in `pkgs/llama-cpp-cuda`), which is what the issue is for.

## Fix agent (`update-fix.yml`)

Dispatched once per failure signature (unit + kind + failed drv names). It
applies the held-back update as a `chore(update): bump <unit>` commit, then
Claude (`claude-code-action`, `CLAUDE_CODE_OAUTH_TOKEN`) returns a verdict:

- `fix-pr`: a minimal fix on `auto/fix-<unit>`, PR referencing the issue;
  merging it lands the bump too, so `landed` clears the unit and closes the issue;
- `upstream`: cites the upstream issue, no PR; the issue closes when it lands;
- `needs-human`: explains, @-mentions the owner.

The agent gets no push token. The workflow commits and pushes its changes after
it exits. Workaround pins, `enable = false` and `allowBroken` are off-limits:
holding an update back is already the bot's job.

## Fix review gate (`update-fix-review.yml`)

Auto-merge is enabled on an `auto/fix-*` PR only if both checks pass:

1. **Hard rules** (`update_bot.py fix-rules`): an optional bump commit
   (flake.lock/pkgs only) plus one fix commit. The fix commit may only
   touch `modules/ pkgs/ hosts/ lib/ flake.nix`, at most 3 files and 40 lines.
   It may not add `enable = false`/`allowBroken`/`allowInsecure`, remove
   `fireproof.*` lines, touch flake.lock, or change a flake `url`.
2. **Review agent**: a separate, read-only Claude run that approves only
   minimal, behavior-preserving fixes.

Otherwise the PR gets `needs-review` and an @-mention.

## GitHub Actions pins

Actions are pinned by SHA with the tag in a comment. `.github/dependabot.yml`
opens one grouped PR a week to bump them (not automerged). Dependabot PRs only
see Dependabot secrets, so `HOMELAB_DOMAIN` and `ATTIC_TOKEN` have to be added
there as well, or the build jobs run without attic and likely time out.
The Determinate Nix version CI installs is pinned separately (`source-tag` in
`.github/actions/setup-nix/action.yml`); bump that one by hand.

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
