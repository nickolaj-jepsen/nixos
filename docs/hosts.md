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
  It defaults to x86_64-linux; another platform sets
  `nixos.nixpkgs.hostPlatform` in the card (`phone-vm`).
- `home` → `homeConfigurations.<h>` via `mkHome` in `hosts/default.nix` (standalone HM, no
  NixOS eval; `osConfig = null`). Example: `dev-ao`. Activate on the host
  itself with `just switch <h>`. HM services that assume system bits (e.g. an
  ssh-agent) must self-provide them in HM or the host card.
- `darwin` → `darwinConfigurations.<h>` via nix-darwin + embedded HM. Example:
  `macbook`. nix-darwin system config (homebrew, …) goes in the `darwin`
  bucket. Activate ON the Mac with `just switch`; the first switch on a fresh
  Mac is below.

`just build`/`switch`/`diff` take any host: they read `config.flake.hostMeta`
(class, rebuild tool, activation attrpath) and run that verb. `boot`/`test` are
nixos-only (they refuse other classes), and `switch` pushes only nixos hosts to
a remote target.

`home`/`darwin` hosts assert their `nixos` bucket empty.

## First switch on a fresh Mac

Run ON the Mac:

1. Install Nix (Determinate or upstream) with flakes enabled.
2. `sudo ssh-keygen -A` — create `/etc/ssh/ssh_host_ed25519_key`.
3. Replace `secrets/hosts/<h>/id_ed25519.{pub,age}` with this Mac's real host
   key (the committed pub is a placeholder), then `just secret-rekey`
   (YubiKey). If `<h>` isn't in `trustedHosts` (`modules/system/ssh.nix`) yet,
   add it now that the real key is committed, and switch the other hosts so
   they accept it.
4. `nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake .#<h>`
   (before the Mac has `darwin-rebuild` on `PATH`). nix-homebrew installs
   Homebrew itself on that first switch (slow); review
   `homebrew.onActivation.cleanup` first.
5. `sudo systemsetup -setremotelogin on` — enable sshd (Remote Login). Nix
   manages the hardening drop-in + `authorized_keys`, but not the on/off bit.
   Confirm Settings > General > Sharing > Remote Login access is "All users"
   (or includes the user). Key-only auth; reach it over Tailscale/LAN.

## The phone (pocketnix)

`phone-vm` is NixOS on the Pixel 8 Pro (GrapheneOS), a headless aarch64 dev
env run by the [pocketnix](https://github.com/nickolaj-jepsen/pocketnix) app
(input `pocketnix`) under Android's AVF: u-boot finds the image's ESP and runs
systemd-boot, so generations and rollback work as on any EFI host. pocketnix's
`nixosModules.default` owns the guest contract (Google's prebuilt guest
kernel, the disk image, first boot, the vsock agent and hvc0 console);
`modules/system/pocketnix.nix` (`fireproof.pocketnix.enable`) wires in the
user, the ssh forward and the terminal's theme and tab profiles. Its
docs/design.md and AGENTS.md hold the platform's decisions and traps. CI
builds it on an arm runner into attic; never evaluate or build on the phone,
it freezes.

- **Image**: `nix build .#nixosConfigurations.phone-vm.config.system.build.pocketnixImage.x86_64-linux`
  (the `x86_64-linux` key assembles it with this machine's tools; the closure
  builds through the desktop's aarch64 binfmt).

One-time bootstrap, over USB with adb:

1. `just provision phone-vm` builds the image, injects the committed SSH host
   key (so agenix decrypts on the first boot), installs the app, grants its
   AVF permissions, pushes the image and starts the VM. Until pocketnix
   publishes releases, pass the APK: `just provision phone-vm --debug --apk
<app-debug.apk>`. `--replace` overwrites an existing guest disk.
2. RAM, vCPUs and disk size live in the app's Settings; the disk grows on the
   next start.
3. The app forwards sshd to the phone's `127.0.0.1:2222`: `adb forward
tcp:2222 tcp:2222`, then `NIX_SSHOPTS="-p 2222" just switch phone-vm
nickolaj@localhost`. Drop any old `[localhost]:2222` known_hosts entry
   first. tailscaled enrols it as `phone-vm`; point the `phone-vm` alias in
   `modules/system/ssh.nix` at its tailnet IP (MagicDNS is off), then
   `just switch phone-vm phone-vm` from then on.

The app's console tab is hvc0 with an autologin, the recovery path; other tabs
run a profile (shell, zellij) through the agent. A guest `reboot` makes the
app relaunch the VM; `poweroff` leaves it stopped.

## Cross-platform apps

Everyday GUI apps have no toggle of their own: they gate on `desktop.enable`
(plus `dev`/`work` where relevant). The darwin host opts into the whole GUI roster with `desktop.enable = true`,
same as Linux. A cross-platform app leaf carries a `flake.modules.darwin.<app>`
half adding a `homebrew.casks` entry, and its homeManager half must keep the
nixpkgs binary off the Mac: `fpLib.mkDarwinGuiPackage` for
`programs.<app>.package`, or `lib.optionals pkgs.stdenv.isLinux [...]` for
`home.packages`. HM halves that can't run on macOS (niri, dms, gtk, clipboard,
Linux-only apps) gate additionally on `pkgs.stdenv.isLinux`. Mac-only apps
(karabiner, bitwarden, linear, …) ship a `darwin` half only. `claude-desktop`
has no nixpkgs build: cask on darwin, repackaged `.deb` in `pkgs/` on Linux.
nixos halves never evaluate on darwin — no guard needed.

## New host / install

- `just new-host <hostname> <username>` drops the card, generates and
  encrypts the host SSH key, `git add`s `hosts/<h>` + `secrets/hosts/<h>`
  (untracked files are invisible to agenix-rekey) and rekeys. Then add `<h>`
  to `trustedHosts` in `modules/system/ssh.nix` so the other hosts accept its
  SSH key.
- Disks: copy a `hosts/_templates/disko/<name>.nix` template into
  `hosts/<h>/` and replace the `@@DISK@@` sentinel with the device. The
  templates are only scaffolding for a card that defines
  `nixos.disko.devices`; `checks.disko-templates` (`home-check.nix`) holds
  them to the card shape.
- Install: `just deploy-remote <h> user@target` runs nixos-anywhere against a
  target already booted into Linux with SSH (cloud VM, recovery shell, the
  generic installer image below). It asks before wiping the target's disks,
  and hands nixos-anywhere the host key plus `secrets/luks-password.age` as
  the disko layout's `/luks-password`. Fragile on flaky networks or hosts that
  auto-reboot during kexec. After first boot, upload
  `secrets/hosts/<h>/id_ed25519.pub` to GitHub to push from the host.
- The generic installer image is the usual target for a physical machine:
  `nix build .#nixosConfigurations.bootstrap.config.system.build.isoImage`
  (its MOTD lists the steps). It is not a host — `installer/` owns it, it
  allows root SSH with password `nixos`, and it installs nothing on its own.
- LUKS hosts can skip the initrd passphrase prompt by enrolling the TPM2 (no
  config change; the systemd initrd ships TPM2 support):
  `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks`.
  With Secure Boot disabled, a stolen powered-off machine then boots straight
  in (a stolen drive stays protected); add `--tpm2-with-pin=yes` for a short
  PIN instead, or roll back with `systemd-cryptenroll --wipe-slot=tpm2 <device>`.
- `just factor <h> [user@target]` rewrites `hosts/<h>/facter.json` by running
  nixos-facter locally or over ssh; it never reinstalls. `modules/base/nix.nix`
  sizes Nix `max-jobs`/`cores` and the tmpfs build dir from it, so a host
  without a report falls back to Nix's (oversubscribing) defaults.

## Tailscale

One tailnet per host — nothing switches profiles
(`modules/system/tailscale.nix`, gated on `fireproof.tailscale.enable`; off
on WSL, which rides the Windows client).

- **Auto-login** (`fireproof.tailscale.autoLogin`, defaults to `enable`):
  `secrets/tailscale-authkey.age` holds an OAuth client secret (admin console →
  Settings → OAuth clients, `auth_keys` write scope, tag `tag:fireproof`; the
  tag needs a `tagOwners` entry in the ACL first). `tailscaled-autoconnect`
  enrols the host on first boot as a tagged node (no key expiry). These hosts
  trust `tailscale0` in the firewall.
- **Manual login** (`autoLogin = false`, e.g. the `work` host): tailscaled with no
  auth key — run `tailscale up` by hand. No secret is decrypted there, and
  `tailscale0` stays untrusted because the host may be pointed at a tailnet
  other than the personal one. The Mac is the same by nature: cask plus one
  GUI login.
- **The work tailnet is never joined from Linux.** `scw-tailnet` sshuttles into
  it through the Mac, the only device enrolled there.
