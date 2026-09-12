# Secrets

agenix-rekey + YubiKey. Host keys: `secrets/hosts/<h>/id_ed25519.{pub,age}`.

```bash
just secret-edit secrets/hosts/<h>/<name>.age   # Edit in $EDITOR (PATH to the .age file, not a bare name)
just secret-rekey                               # Rekey after adding hosts/secrets (YubiKey touch)
printf 'KEY=value\n' | just secret-write secrets/hosts/<h>/<name>.age  # From stdin, no editor
```

Only commands that **decrypt** need the YubiKey. Encryption uses recipient
pubkeys alone, so `secret-write` creates a **new** secret unattended — use it
when a new service's secret must exist before the flake evaluates. It refuses
to overwrite without `force=1` (stdin replaces the file wholesale).
`secret-edit` and `secret-rekey` both decrypt → both need a touch; builds fail
with "Rekeyed secret not found" until `secret-rekey` has run.

## Two rekey stores per host

`agenix rekey` deletes any file in a node's `localStorageDir` the node doesn't
own, so the nixos and HM nodes of one host must not share a dir:

- `secrets/hosts/<h>/.rekey/` — nixos secrets (`modules/base/secrets.nix`):
  `age.secrets.*` declared in a `flake.modules.nixos.*` half, decrypted by root.
- `secrets/hosts/<h>/.rekey-hm/` — home-manager secrets
  (`modules/base/hm-secrets.nix`): declared in a `flake.modules.homeManager.*`
  half, decrypted during HM activation as the user via `~/.ssh/id_ed25519`.
  The `ssh-key` secret stays nixos-side because it IS that identity.

Both stores use the same `hostPubkey`, so the blobs are interchangeable.

## Darwin

agenix-rekey auto-discovers `darwinConfigurations`. A not-yet-deployed Mac
ships the agenix-rekey dummy pubkey as its `id_ed25519.pub` so the flake still
evaluates; first bootstrap replaces it (`sudo ssh-keygen -A` → real
`/etc/ssh/ssh_host_ed25519_key.pub` → `just secret-rekey`).

## Rekeying from WSL

`desktop-wsl` drives the YubiKey itself — the master identity is PIN/touch
policy "Never", so nothing prompts inside WSL. Two config pieces make it work:
`boot.kernelModules = ["vhci-hcd"]` (`modules/system/wsl.nix`; without it the
`usbip-auto-attach@` units spin on a missing `/sys/devices/platform/vhci_hcd.0`)
and a polkit rule granting wheel `org.debian.pcsc-lite.access_{pcsc,card}`
(`modules/system/yubikey.nix`; pcscd's defaults only allow an active logind
session, excluding systemd units and agent shells).

Windows side, once per key: `usbipd bind --busid <id>` from an admin shell.
Busids are per **port** — reuse the same one, or run `usbipd list` and update
`wsl.usbip.autoAttach` in `hosts/desktop-wsl/system.nix`. While attached the
key is invisible to Windows: no WebAuthn or Windows Hello until `usbipd detach`.
