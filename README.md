# NixOS Configuration

Personal NixOS configuration using flakes, home-manager, and agenix for secret management.

## Quick Start

All common tasks are managed via `just`; run `just` to list every recipe with
its description.

```bash
just switch                  # Rebuild and switch this machine
just switch desktop          # ...or a specific host
just switch host user@remote # ...or a remote host (nixos-rebuild --target-host)
just test                    # Apply until reboot
just build-system            # Build without switching
just update                  # Update flake inputs
just fmt                     # Format everything
just gc                      # Collect garbage and delete old generations
```

## Options Reference

This config exposes a custom `fireproof.*` options namespace. A generated
Markdown reference — descriptions, types, defaults, and declaration links — is
available at [docs/fireproof-options.md](docs/fireproof-options.md). CI
regenerates it after each push to main.

## Installing on a New Machine

```bash
just new-host <hostname> <username>       # card, SSH key, rekey (YubiKey)
just deploy-remote <hostname> root@<ip>   # nixos-anywhere: formats the target's disks
```

`deploy-remote` installs onto a target already booted into a Linux with SSH:
the generic installer image, any NixOS ISO, or a cloud VM. The target's disks
come from the host's `hosts/<hostname>/` cards (see the disko templates), and
nixos-anywhere wipes whatever is on them.

The full procedure, including disk layouts, TPM2 unlock and installing to a
fresh Mac, is in [docs/hosts.md](docs/hosts.md#new-host--install).

## Secret Management

Secrets are managed with [agenix](https://github.com/ryantm/agenix) + [agenix-rekey](https://github.com/oddlama/agenix-rekey), using a YubiKey as the master identity.

Layout, commands and YubiKey requirements are in
[docs/secrets.md](docs/secrets.md); `just` lists the secret recipes.

## Development

### Development Shell

A Nix development shell is available with useful tools for working on this configuration:

```bash
# Enter the development shell
nix develop
```

### Formatting

Code is formatted with `treefmt-nix`; the formatters are configured in
[formatter.nix](formatter.nix).

```bash
just fmt
```

## Theme

Heavily inspired by / stolen from [Flexoki](https://stephango.com/flexoki)

The palette is the `fireproof.theme.colors` options in
[modules/base/theme.nix](modules/base/theme.nix); defaults are listed in
[docs/fireproof-options.md](docs/fireproof-options.md).
