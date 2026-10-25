# Hosts and host cards

Read this before adding a host, editing `hosts/`, or making an app
cross-platform.

## Cards

- A host is any `hosts/<name>/` directory containing a `host.nix`. Discovery is
  automatic (`hosts/default.nix`); there is no registry.
- **Every** `.nix` file in a host dir is a card of the shape
  `{ class?; aliases?; shared?; nixos?; homeManager?; darwin?; }`. The collector throws
  on a bare NixOS module and points you at the `nixos` bucket.
- Buckets merge across all cards in the dir, so config can live in `host.nix`
  or in siblings (`system.nix`, `monitors.nix`, or a feature co-located with
  its config, e.g. minilab's `snapcast.nix`).
- `shared` is merged into both the nixos and home-manager evals; there is no
  osConfig bridge.
  - A "fact" is just a `fireproof.*` value set in `shared`. The toggle
    `fireproof.<feature>.enable = true` is the fact that gates the feature's
    leaves.
  - Hosts set parent toggles and override the exceptions, e.g. minilab sets
    `desktop.enable = true` and then `desktop.chromium.enable = false`.
- `nixos` / `homeManager` / `darwin` are per-class config buckets. They are
  plain modules with no `inputs`/`fpLib` args (no specialArgs), so anything
  needing a flake input belongs in a leaf under `modules/`.
- `state-version.nix` pins `system.stateVersion` and `home.stateVersion` per
  host. `just new-host` stamps it, and there is no fleet-wide default. Never
  bump it.
- Every toggle is declared in all module classes (centrally, in
  `modules/base/fireproof.nix`) so `shared` values reach every eval.

## Classes

`class` is the one scalar a card may carry: `"nixos"` (default), `"home"` or
`"darwin"`. `validClasses` in `hosts/default.nix` lists them, and a typo
throws. The class routes the whole host:

- `nixos` → `nixosConfigurations.<h>` via `nixosSystem`. The host builder
  defines `home-manager.users.<fireproof.username>` and routes all homeManager
  leaves plus the card's `shared`/`homeManager` buckets into `sharedModules`.
  - It defaults to x86_64-linux; another platform sets
    `nixos.nixpkgs.hostPlatform` in the card (`phone-vm`).
- `home` → `homeConfigurations.<h>` via `mkHome` in `hosts/default.nix`.
  Example: `dev-ao`.
  - It is standalone HM with no NixOS eval; `osConfig = null`.
  - Activate with `just switch <h> [user@target]`. The target needs the user
    in `trusted-users`.
  - HM services that assume system bits (e.g. an ssh-agent) must provide them
    themselves, in HM or the host card.
- `darwin` → `darwinConfigurations.<h>` via nix-darwin with embedded HM.
  Example: `macbook`.
  - nix-darwin system config (homebrew, …) goes in the `darwin` bucket.
  - Activate on the Mac itself with `just switch`. The first switch on a fresh
    Mac is below.
- `home`/`darwin` hosts assert their `nixos` bucket is empty.

`aliases` lists machine hostnames (`hostname -s`) that mean this host when
they differ from its dir name, e.g. dev-ao's `["dev-01"]`. A verb run without
a host resolves through `config.flake.hostAliases`; an alias that shadows a
host or is claimed twice throws.

Verbs per class:

- `just build`/`switch`/`diff` take any host. They read
  `config.flake.hostMeta` (class, rebuild tool, activation attrpath) and run
  that verb.
- `boot`/`test` are nixos-only and refuse other classes.
- `switch` pushes only nixos hosts to a remote target.

## First switch on a fresh Mac

Run these on the Mac:

1. Install Nix (Determinate or upstream) with flakes enabled.
2. `sudo ssh-keygen -A` creates `/etc/ssh/ssh_host_ed25519_key`.
3. Replace `secrets/hosts/<h>/id_ed25519.{pub,age}` with this Mac's real host
   key (the committed pub is a placeholder), then run `just secret-rekey`
   (YubiKey). If `<h>` isn't in `trustedHosts` (`modules/system/ssh.nix`) yet,
   add it now that the real key is committed, and switch the other hosts so
   they accept it.
4. Before the Mac has `darwin-rebuild` on `PATH`, run
   `nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake .#<h>`.
   nix-homebrew installs Homebrew itself on that first switch, which is slow.
   Review `homebrew.onActivation.cleanup` first.
5. `sudo systemsetup -setremotelogin on` enables sshd (Remote Login).
   - Nix manages the hardening drop-in and `authorized_keys`, but not the
     on/off bit.
   - Confirm that Settings > General > Sharing > Remote Login access is "All
     users" (or includes the user).
   - Auth is key-only; reach it over Tailscale or the LAN.

## The phone (Podroid)

`phone-vm` is NixOS on the Pixel 8 Pro (GrapheneOS), a headless aarch64 dev
env run by a fork of Podroid (input `podroid`, branch `nixos-image`) in its AVF
disk-image mode: AVF's u-boot finds the image's ESP and runs systemd-boot, so
generations and rollback work as on any EFI host. The guest half is
`modules/system/avf.nix` (`fireproof.avf.enable`) plus the fork's
`nixosModules.guest`. CI builds it on an arm runner into attic; never evaluate
or build on the phone, it freezes.

- **Kernel**: `pkgs/avf-kernel`, Google's prebuilt guest kernel from the
  Android Terminal's image archive. Every nixpkgs kernel tried (6.1 to 6.18)
  reads corrupted data from the virtio disk under the Pixel's pKVM (ext4
  checksum errors, random SEGVs); re-test with a read-hash loop before
  switching back. The archive's URL is unversioned, so a hash failure means
  Google shipped a new kernel to vet.
- **Image**: `nix build .#nixosConfigurations.phone-vm.config.system.build.avfImage.x86_64-linux`
  (the `x86_64-linux` key assembles it with this machine's tools; the closure
  builds through the desktop's aarch64 binfmt).

One-time bootstrap:

1. Install the fork's APK and finish its first-run setup; pick the storage
   size there (Settings later). It only offers sizes that fit the phone's free
   space, and the image grows on the next VM start.
2. Settings → Disk image → import the `.raw`, then start the VM. It boots to an
   autologin shell; Home Manager fails until step 4.
3. Add a port forward `2222 → 22` (it binds every interface; sshd is key-only)
   and `adb forward tcp:2222 tcp:2222`.
4. `just push-host-key phone-vm nickolaj@localhost -p 2222` installs the
   committed host key and reboots, so agenix decrypts and HM activates. The
   host key changes under you here: drop any `[localhost]:2222` entry first.
5. `NIX_SSHOPTS="-p 2222" just switch phone-vm nickolaj@localhost`. tailscaled
   enrols it as `phone-vm`; point the `phone-vm` alias in
   `modules/system/ssh.nix` at its tailnet IP (MagicDNS is off), then
   `just switch phone-vm phone-vm` from then on.

A guest `reboot` makes the app relaunch the VM; `poweroff` leaves it stopped.

## Cross-platform apps

- Everyday GUI apps have no toggle of their own: they gate on `desktop.enable`
  (plus `dev`/`work` where relevant).
- The darwin host opts into the whole GUI roster with `desktop.enable = true`,
  same as Linux.
- A cross-platform app leaf carries a `flake.modules.darwin.<app>` half that
  adds a `homebrew.casks` entry.
- Its homeManager half must keep the nixpkgs binary off the Mac:
  `fpLib.mkDarwinGuiPackage` for `programs.<app>.package`, or
  `lib.optionals pkgs.stdenv.isLinux [...]` for `home.packages`.
- HM halves that can't run on macOS (niri, dms, gtk, clipboard, Linux-only
  apps) also gate on `pkgs.stdenv.isLinux`.
- Mac-only apps (karabiner, bitwarden, linear, …) ship a `darwin` half only.
- `claude-desktop` has no nixpkgs build: it is a cask on darwin and a
  repackaged `.deb` in `pkgs/` on Linux.
- nixos halves never evaluate on darwin, so they need no guard.

## New host / install

- `just new-host <hostname> <username>` drops the card, generates and encrypts
  the host SSH key, `git add`s `hosts/<h>` and `secrets/hosts/<h>` (untracked
  files are invisible to agenix-rekey) and rekeys.
  - Then add `<h>` to `trustedHosts` in `modules/system/ssh.nix` so the other
    hosts accept its SSH key.
- Disks: copy a `hosts/_templates/disko/<name>.nix` template into
  `hosts/<h>/` and replace the `@@DISK@@` sentinel with the device.
  - The templates are only scaffolding for a card that defines
    `nixos.disko.devices`.
  - `checks.disko-templates` (`home-check.nix`) holds them to the card shape.
- Install: `just deploy-remote <h> user@target` runs nixos-anywhere against a
  target already booted into Linux with SSH (cloud VM, recovery shell, the
  generic installer image below).
  - It asks before wiping the target's disks.
  - It hands nixos-anywhere the host key, plus `secrets/luks-password.age` as
    the disko layout's `/luks-password`.
  - It is fragile on flaky networks and on hosts that auto-reboot during
    kexec.
  - After first boot, upload `secrets/hosts/<h>/id_ed25519.pub` to GitHub to
    push from the host.
- The generic installer image is the usual target for a physical machine:
  `nix build .#nixosConfigurations.bootstrap.config.system.build.isoImage`.
  - Its MOTD lists the steps.
  - It is not a host; `installer/` owns it.
  - It allows root SSH with password `nixos`, and installs nothing on its own.
- LUKS hosts can skip the initrd passphrase prompt by enrolling the TPM2:
  `sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks`.
  - It needs no config change; the systemd initrd ships TPM2 support.
  - With Secure Boot disabled, a stolen powered-off machine then boots straight
    in. A stolen drive stays protected.
  - Add `--tpm2-with-pin=yes` for a short PIN instead, or roll back with
    `systemd-cryptenroll --wipe-slot=tpm2 <device>`.
  - Never enroll a TPM-only slot on a host with `fireproof.desktop.autologin`:
    it would boot to a signed-in desktop with no secret asked at all.
- `just factor <h> [user@target]` rewrites `hosts/<h>/facter.json` by running
  nixos-facter locally or over ssh. It never reinstalls.
  - `modules/base/nix.nix` sizes Nix `max-jobs`/`cores` and the tmpfs build
    dir from that report, so a host without one falls back to Nix's
    (oversubscribing) defaults.

## Tailscale

Each host is on one tailnet, and nothing switches profiles. The module is
`modules/system/tailscale.nix`, gated on `fireproof.tailscale.enable`. It is
off on WSL, which rides the Windows client.

- Auto-login (`fireproof.tailscale.autoLogin`, defaults to `enable`):
  - `secrets/tailscale-authkey.age` holds an OAuth client secret: admin console
    → Settings → OAuth clients, `auth_keys` write scope, tag `tag:fireproof`.
  - The tag needs a `tagOwners` entry in the ACL first.
  - `tailscaled-autoconnect` enrols the host on first boot as a tagged node,
    with no key expiry.
  - These hosts trust `tailscale0` in the firewall.
- Manual login (`autoLogin = false`, e.g. the `work` host):
  - tailscaled runs with no auth key; run `tailscale up` by hand.
  - No secret is decrypted there.
  - `tailscale0` stays untrusted, because the host may be pointed at a tailnet
    other than the personal one.
  - The Mac is the same by nature: cask plus one GUI login.
- The work tailnet is **never** joined from Linux. `scw-tailnet` sshuttles into it
  through the Mac, the only device enrolled there.
