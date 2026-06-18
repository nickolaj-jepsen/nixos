# nix-on-droid (Nix on Android) — proof of concept

This directory is a **proof of concept** for running parts of this configuration
on Android via [nix-on-droid](https://github.com/nix-community/nix-on-droid).

## What this is (and isn't)

nix-on-droid is a Termux-like Android app that runs the **Nix package manager**
and **home-manager** in an Android userspace (via proot). It is **not** NixOS:

- No systemd, no NixOS module layer, no `niri`/desktop, no homelab services.
- The `fireproof.*` modules in `modules/` are **NixOS** modules and cannot be
  imported here, so the phone config (`phone/default.nix`) is **self-contained**:
  a curated list of portable CLI tools plus a small home-manager config.

For *real* NixOS on a phone (replacing Android, requires a supported device +
flashing) see [mobile-nixos](https://github.com/NixOS/mobile-nixos) — out of
scope for this PoC.

## Layout

- `default.nix` — flake-parts module exposing `nixOnDroidConfigurations.phone`.
  Builds directly against `nixpkgs.legacyPackages.aarch64-linux` so we don't add
  `aarch64-linux` to the flake's top-level `systems`.
- `phone/default.nix` — the self-contained device config (packages + home-manager
  + an inert agenix secrets scaffold).

## Building / deploying

Unlike the NixOS hosts, there is **no ISO and no remote deploy**. You install
the app and activate on the device itself:

1. Install the nix-on-droid APK (F-Droid or the GitHub releases).
2. Get this flake onto the phone (clone it, or `nix-on-droid switch` against the
   remote flake URL).
3. On the phone:
   ```sh
   nix-on-droid switch --flake .#phone
   ```
   Builds run natively on aarch64 (or substitute from a binary cache).

> **Note:** This PoC adds the `nix-on-droid` flake **input** but the `flake.lock`
> was **not** updated in the branch (the CI sandbox that authored it has no `nix`
> binary). Run `nix flake lock` (or `just update`) once locally before building,
> otherwise evaluation will fail on the missing lock entry.

## Secrets (agenix) — optional, manual

The rest of this flake uses **system-level** agenix. nix-on-droid has no NixOS
layer, so the phone uses the **home-manager** agenix modules instead
(`inputs.agenix.homeManagerModules.default` +
`inputs.agenix-rekey.homeManagerModules.default`). The wiring lives in
`phone/default.nix` but is **disabled** until the phone's public key exists, so
the PoC builds as a pure CLI environment out of the box.

To turn it on:

1. **Generate an identity on the phone** (inside nix-on-droid):
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
   ```
   The **private** key stays on the device — it becomes the agenix decryption
   identity (`age.identityPaths`). Never commit it.
2. **Register the public key** as a recipient:
   ```sh
   cp id_ed25519.pub secrets/hosts/phone/id_ed25519.pub   # from the phone to the repo
   ```
   This flips the `builtins.pathExists` guard and activates the agenix block.
3. **Rekey on your desktop with the YubiKey** (the master identity):
   ```sh
   just secret-rekey
   ```
   This re-encrypts the selected secrets so the phone's key can decrypt them.
4. Re-run `nix-on-droid switch --flake .#phone` on the phone.

### Making `just secret-rekey` aware of the phone

`agenix-rekey` auto-discovers `nixosConfigurations` (and home-manager nested in
them) plus standalone `homeConfigurations`. It does **not** scan
`nixOnDroidConfigurations`. To include the phone in rekeying, expose its
home-manager config to agenix-rekey — e.g. add a `homeConfigurations.phone`
output or set `perSystem.agenix-rekey.homeConfigurations.phone` to the phone's
home-manager configuration (the attr needs a `config.age`). This step is left
out of the PoC because it only matters once you have the YubiKey + on-device key
to actually rekey.

### Security note

A phone is a higher-loss-risk device than your desktops/servers. Every secret
you rekey to it is decryptable by anyone who extracts the on-device private key,
so **rekey only a deliberately chosen allowlist** of user-level secrets — never
the host/server set. And never reference a plaintext private key from any Nix
config: it would be copied into the world-readable Nix store.
