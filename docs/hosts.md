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
- `nixos` / `homeManager` / `darwin` are per-class config buckets.
- Every toggle is declared in all module classes (centrally, in
  `modules/base/fireproof.nix`) so `shared` values reach every eval.

## Classes

`class` is the one scalar a card may carry — `"nixos"` (default), `"home"`, or
`"darwin"` (`validClasses` in `hosts/default.nix`; a typo throws). It routes
the whole host:

- `nixos` → `nixosConfigurations.<h>` via `nixosSystem`. The host builder
  defines `home-manager.users.<fireproof.username>` and routes all homeManager
  leaves + the card's `shared`/`homeManager` buckets into `sharedModules`.
- `home` → `homeConfigurations.<h>` via `lib/mkHome.nix` (standalone HM, no
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

- `just new-host <hostname> <username>` drops the card + generates and
  encrypts the host SSH key.
- Physical install: `just bootstrap-iso <h>` bakes the host key + this flake
  into an ISO; `just bootstrap-flash <h> /dev/sdX`; target boots and runs
  `bootstrap-install`. The installer lives in `installer/` (a self-contained
  corner owning `nixosConfigurations.bootstrap{,-<host>}`, not a host).
- Disko templates: `hosts/_templates/disko/<name>.nix` with
  `device = "@@DISK@@";` as the sentinel; the installer offers any template
  found there when the host has no `disk-configuration.nix` yet.

## Tailscale

One tailscaled per host, `tailscale switch` between profiles — never two
tailnets at once (`modules/system/tailscale.nix`, `modules/scripts/tailnet.bash`).

- **Personal tailnet is declarative.** `secrets/tailscale-authkey.age` holds an
  OAuth client secret (admin console → Settings → OAuth clients, `auth_keys`
  write scope, tag `tag:fireproof`; the tag needs a `tagOwners` entry in the
  ACL first). `tailscaled-autoconnect` enrols every NixOS host on first boot as
  a tagged node (no key expiry). The Mac logs in once via the GUI.
- **Work tailnet is manual** (work-enabled hosts only): once per host, run
  `tailscale login` while on the personal profile to add the second profile.
  `tailnet toggle` (also the DMS bar widget) switches; boot always lands on the
  personal profile. Work-enabled hosts don't trust `tailscale0` in the firewall,
  so switching never exposes anything not opened explicitly.
