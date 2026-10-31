# Secrets

Secrets use agenix-rekey with a YubiKey.

- Host keys are `secrets/hosts/<h>/id_ed25519.{pub,age}`.
- `secrets/yubikey-identity.age` is a passphrase-encrypted offline backup of the
  YubiKey identity. Nothing references it by design, so don't prune it.

```bash
just secret-edit secrets/hosts/<h>/<name>.age   # Edit in $EDITOR (PATH to the .age file, not a bare name)
just secret-rekey                               # Rekey after adding hosts/secrets (YubiKey touch)
printf 'KEY=value\n' | just secret-write secrets/hosts/<h>/<name>.age  # From stdin, no editor
```

## Which commands need the YubiKey

- Only commands that decrypt need it. Encryption uses the recipient pubkeys
  alone.
- So `secret-write` creates a new secret unattended. Use it when a new service's
  secret must exist before the flake evaluates.
- `secret-write` refuses to overwrite without `force=1`, and stdin replaces the
  file wholesale.
- `secret-edit` and `secret-rekey` both decrypt, so both need a touch.
- Builds fail with "Rekeyed secret not found" until `secret-rekey` has run.

## Generated secrets

Use a generator for a new secret that is only random material nobody outside
this repo needs to know (an internal DB password, a cookie/session key). Skip
`secret-write` and let agenix-rekey create it:

```nix
age.secrets.foo-db-pass.generator.script = "alnum";
```

- Leave out `rekeyFile`: it defaults to
  `secrets/hosts/<h>/generated/<name>.age`.
- Then run `just secret-generate` (no YubiKey) and `just secret-rekey`.
- `generate` deletes any `*.age` in `generated/` that no generator owns. Never
  point `generatedSecretsDir` (`lib/default.nix`) at the hand-written secrets.
- Don't retrofit a generator onto an existing secret: `generate -f` would rotate
  it, which is fatal for `restic-password` and `zitadel-master`.

## Two rekey stores per host

`agenix rekey` deletes any file in a node's `localStorageDir` that the node
doesn't own, so the nixos and HM nodes of one host must not share a dir.

- `secrets/hosts/<h>/.rekey/` holds nixos secrets (`modules/base/secrets.nix`):
  `age.secrets.*` declared in a `flake.modules.nixos.*` half, decrypted by root.
- `secrets/hosts/<h>/.rekey-hm/` holds home-manager secrets
  (`modules/base/hm-secrets.nix`): declared in a `flake.modules.homeManager.*`
  half, decrypted during HM activation as the user via `~/.ssh/id_ed25519`.
- The `ssh-key` secret stays nixos-side because it is that identity.
- Both stores use the same `hostPubkey`, so the blobs are interchangeable.
- After narrowing a host's secret set, run `just secret-rekey`. Orphans are
  pruned only there, and until then they ship in that host's store copy of the
  dir.

## Darwin

- agenix-rekey auto-discovers `darwinConfigurations`.
- A not-yet-deployed Mac ships the agenix-rekey dummy pubkey as its
  `id_ed25519.pub`, so the flake still evaluates.
- The first bootstrap replaces it: `sudo ssh-keygen -A` creates the real
  `/etc/ssh/ssh_host_ed25519_key.pub`, then run `just secret-rekey`.
- Only then add the host to `trustedHosts` in `modules/system/ssh.nix`. That
  list is what authorizes a host's key for SSH logins fleet-wide.

## Rekeying from WSL

`desktop-wsl` drives the YubiKey itself. The master identity's PIN/touch policy
is "Never", so nothing prompts inside WSL. It needs this config:

- `boot.kernelModules = ["vhci-hcd"]` in `modules/system/wsl.nix`. Without it
  the `usbip-auto-attach@` units spin on a missing
  `/sys/devices/platform/vhci_hcd.0`.
- A polkit rule in `modules/system/yubikey.nix` granting wheel
  `org.debian.pcsc-lite.access_{pcsc,card}`. pcscd's defaults allow only an
  active logind session, which excludes systemd units and agent shells.

On the Windows side:

- Once per key, run `usbipd bind --busid <id>` from an admin shell.
- Busids are per port. Keep the key on the same port, or run `usbipd list` and
  update `wsl.usbip.autoAttach` in `hosts/desktop-wsl/system.nix`.
- While attached, the key is invisible to Windows: no WebAuthn or Windows Hello
  until `usbipd detach`.
