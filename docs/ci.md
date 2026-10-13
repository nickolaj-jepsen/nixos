# CI

`.github/workflows/fmt.yml` (workflow "CI") runs on pushes to `main` and on PRs.
`CI gate` is the only required check.

- `fmt`: `nix fmt -- --fail-on-change`.
- `hosts`: lists the `nixosConfigurations` to build (minus `bootstrap-*`) and
  decides whether the builds go to the homelab runner.
- `check`: builds `checks.x86_64-linux` and evaluates what no build job covers:
  bootstrap hosts, packages, dev shells.
- `build (<host>)`: `ci-build.sh`, i.e. `nix-fast-build --skip-cached`. A host
  whose toplevel is already in attic passes without downloading anything. On a
  timeout it prints the markers `update_bot.py triage` reads.
- `darwin`: the same for the Mac, on `macos-latest`.

Hosted jobs push to attic through `setup-nix` (attic-action, `ATTIC_TOKEN`).

## Homelab runner

Building a changed host means having its whole closure on the runner: about
5.6 GiB for desktop, half of it unfree packages that only attic has, served over
the homelab's uplink while laptop and work fetch the same. On the homelab the
store persists and attic is local.

`modules/homelab/ci-runner.nix` (`fireproof.homelab.ci-runner.enable`) runs
three ephemeral runners labeled `homelab`. When `hosts` says so, the
`build-homelab` job runs there instead of `build`. Both are named
`build (<host>)`, so triage and the gate treat them the same. That happens only
if:

- the repo variable `HOMELAB_RUNNER` is `true`, and
- the run is a push to `main` or the update bot's PR (`auto/update`).

That is code which reaches every host anyway. All other PRs use hosted runners,
including yours, agent-written branches and forks.

**Kill switch**: `gh variable set HOMELAB_RUNNER --body false`. The next run
uses hosted runners and no deploy is needed. Do this whenever the homelab is down:
queued homelab jobs otherwise wait a day before failing.

### Enabling

1. A fine-grained PAT for this repo only, with Administration read/write (lets
   the runners mint their registration tokens):
   `printf %s "$PAT" | just secret-write secrets/hosts/homelab/github-runner-token.age`.
2. On the homelab, an attic token for the post-build-hook:
   `sudo atticd-atticadm make-token --sub homelab-post-build-hook --validity 1y --pull nixos --push nixos`,
   then `printf %s "$TOKEN" | just secret-write secrets/hosts/homelab/attic-push-token.age`.
3. `just secret-rekey`, then `shared.fireproof.homelab.ci-runner.enable = true;`
   in `hosts/homelab/host.nix` and `just switch homelab`.
4. `gh api repos/nickolaj-jepsen/nixos/actions/runners --jq '.runners[] | [.name, .status] | @tsv'`
   lists three idle runners.
5. `gh variable set HOMELAB_RUNNER --body true`.

Both tokens expire; renew them with `just secret-edit`.

### Security invariants

The repo is public, so anyone can open a PR whose workflow targets the
`homelab` label. Keep these true:

- **Fork PRs need approval** (Settings → Actions → "Require approval for all
  external contributors", API `fork-pr-contributor-approval` =
  `all_external_contributors`). A PR runs its own copy of the workflows, so an
  approved fork run can target `homelab` itself. Read every change under
  `.github/` before approving one.
- **Only main and `auto/update` route to the homelab.** A branch's own copy of
  the workflow decides, so this only keeps ordinary PRs off it. Anyone who can
  push workflow changes can still target it. The fix agent can't: `publish`
  refuses anything under `.github/`.
- **`build-homelab` references no secrets.** A job receives every secret it
  references, even in a skipped step. Attic pushes happen in the host's
  `post-build-hook` with a token jobs can't read.
- **Runner users are `allowed-users`, never `trusted-users`.** A trusted user
  can choose substituters and turn off the sandbox, which is root.
- **The egress firewall stays.** Runner users and `nixbld` (fixed-output
  builds have network access) can reach the internet over IPv4 and resolved's
  stub only. Not the LAN, the tailnet, docker, multicast, or this host's own
  addresses, where the services behind nginx's SSO listen. No IPv6: the LAN's
  global prefix comes from the ISP, so it can't be listed. The runners also
  can't open root daemons' sockets (tailscaled's is world-writable and dials the
  tailnet as root), and they stop whenever the firewall does.
