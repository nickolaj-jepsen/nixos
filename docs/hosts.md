# Hosts and host cards

Read this before adding a host, editing `hosts/`, or making an app
cross-platform.

## Cards

A host is any `hosts/<name>/` directory containing a `host.nix` — discovery is
automatic (`hosts/default.nix`), no registry. **Every** `.nix` file in a host
dir is a card of the shape `{ class?; shared?; nixos?; homeManager?; darwin?; }`;
the collector throws on a bare NixOS module, pointing you at the `nixos`
bucket. Buckets merge across all cards in the dir, so config can live in
`host.nix` or siblings (`system.nix`, `monitors.nix`, or a feature co-located
with its config, e.g. minilab's `snapcast.nix`).

- `shared` is merged into BOTH the nixos and home-manager evals (no osConfig
  bridge) — a "fact" is just a `fireproof.*` value set here, and the toggle
  `fireproof.<feature>.enable = true` IS the fact that gates the feature's
  leaves. Hosts set parent toggles and override exceptions (e.g. minilab sets
  `desktop.enable = true` then `desktop.chromium.enable = false`).
- `nixos` / `homeManager` / `darwin` are per-class config buckets. They are
  plain modules with no `inputs`/`fpLib` args (no specialArgs) — anything
  needing a flake input belongs in a leaf under `modules/`.
- `state-version.nix` pins `system.stateVersion` + `home.stateVersion` per host
  (stamped by `just new-host`; there is no fleet-wide default). Never bump it.
- Every toggle is declared in all module classes (centrally, in
  `modules/base/fireproof.nix`) so `shared` values reach every eval.

## Classes

`class` is the one scalar a card may carry — `"nixos"` (default), `"home"`, or
`"darwin"` (`validClasses` in `hosts/default.nix`; a typo throws). It routes
the whole host:

- `nixos` → `nixosConfigurations.<h>` via `nixosSystem`. The host builder
  defines `home-manager.users.<fireproof.username>` and routes all homeManager
  leaves + the card's `shared`/`homeManager` buckets into `sharedModules`.
- `home` → `homeConfigurations.<h>` via `mkHome` in `hosts/default.nix` (standalone HM, no
  NixOS eval; `osConfig = null`). Example: `dev-ao`. Activate with
  `just home-switch <h> [user@target]`; the target needs the user in
  `trusted-users`. HM services that assume system bits (e.g. an ssh-agent)
  must self-provide them in HM or the host card.
- `darwin` → `darwinConfigurations.<h>` via nix-darwin + embedded HM. Example:
  `macbook`. nix-darwin system config (homebrew, …) goes in the `darwin`
  bucket. Activate ON the Mac with `just darwin-switch`; first-time bootstrap
  notes live in the justfile.

`home`/`darwin` hosts assert their `nixos` bucket empty.
`config.flake.hostNames` (the installer's bootstrap fan-out) is nixos hosts
only.

## Cross-platform apps

The darwin host opts into the whole GUI roster with `desktop.enable = true`,
same as Linux. A cross-platform app leaf carries a `flake.modules.darwin.<app>`
half adding a `homebrew.casks` entry, and its homeManager half must keep the
nixpkgs binary off the Mac: `fpLib.mkDarwinGuiPackage` for
`programs.<app>.package`, or `lib.optionals pkgs.stdenv.isLinux [...]` for
`home.packages`. HM halves that can't run on macOS (niri, dms, gtk, clipboard,
Linux-only apps) gate additionally on `pkgs.stdenv.isLinux`. Mac-only apps
(karabiner, bitwarden, linear, …) ship a `darwin` half only. `claude-desktop`
has no nixpkgs build: cask on darwin, repackaged `.deb` overlay on Linux.
nixos halves never evaluate on darwin — no guard needed.

## New host / install

- `just new-host <hostname> <username>` drops the card, generates and
  encrypts the host SSH key, `git add`s `hosts/<h>` + `secrets/hosts/<h>`
  (untracked files are invisible to agenix-rekey) and rekeys. Then add `<h>`
  to `trustedHosts` in `modules/system/ssh.nix` so the other hosts accept its
  SSH key.
- Physical install: `just bootstrap-iso <h>` bakes the host key + this flake
  into `~/.cache/bootstrap-iso/<h>.iso` and purges the key's copies from the
  Nix store; `just bootstrap-flash <h> /dev/sdX`; target boots and runs
  `bootstrap-install`. Wipe the stick afterwards (it holds the key). The
  installer lives in `installer/` (a self-contained corner owning
  `nixosConfigurations.bootstrap{,-<host>}`, not a host). Host-baked images
  run no sshd; only the generic `bootstrap` image allows root password SSH,
  for `just deploy-remote`.
- Disko templates: `hosts/_templates/disko/<name>.nix` are host cards
  (`{ nixos.disko.devices = …; }`) with `device = "@@DISK@@";` as the
  sentinel; `checks.disko-templates` (`home-check.nix`) enforces that shape.
  The installer keeps an existing layout (any host file defining
  `disko.devices`) and offers the templates when there is none, or to replace
  one that lives in `disk-configuration.nix`.
- `just factor <h> [user@target]` rewrites `hosts/<h>/facter.json` by running
  nixos-facter locally or over ssh; it never reinstalls. `modules/base/nix.nix`
  sizes Nix `max-jobs`/`cores` and the tmpfs build dir from it, so a host
  without a report falls back to Nix's (oversubscribing) defaults.

## Tailscale

One tailnet per host — nothing switches profiles
(`modules/system/tailscale.nix`, gated on `fireproof.tailscale.enable`; off
only for desktop-wsl, which rides the Windows client).

- **Auto-login** (`fireproof.tailscale.autoLogin`, defaults to `enable`):
  `secrets/tailscale-authkey.age` holds an OAuth client secret (admin console →
  Settings → OAuth clients, `auth_keys` write scope, tag `tag:fireproof`; the
  tag needs a `tagOwners` entry in the ACL first). `tailscaled-autoconnect`
  enrols the host on first boot as a tagged node (no key expiry). These hosts
  trust `tailscale0` in the firewall.
- **Manual login** (`autoLogin = false`, the `work` host): tailscaled with no
  auth key — run `tailscale up` by hand. No secret is decrypted there, and
  `tailscale0` stays untrusted because the host may be pointed at a tailnet
  other than the personal one. The Mac is the same by nature: cask plus one
  GUI login.
- **The work tailnet is never joined from Linux.** `scw-tailnet` sshuttles into
  it through the Mac, the only device enrolled there.
