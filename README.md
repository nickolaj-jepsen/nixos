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

New machines are installed from a host-specific bootstrap ISO: an install
image with the new host's pre-rekeyed SSH key and a copy of this flake baked
in. The target boots the USB and runs `bootstrap-install`, with no GitHub
roundtrip and no manual rekeying on the target.

```bash
just new-host <hostname> <username>          # card, SSH key, rekey (YubiKey)
just bootstrap-iso <hostname>                # build the host's install ISO
just bootstrap-flash <hostname> /dev/sdX     # flash it to USB
bootstrap-install                            # on the target, after booting the USB
```

The full procedure, including disk layouts, TPM2 unlock and remote installs
via nixos-anywhere, is in [docs/hosts.md](docs/hosts.md#new-host--install).

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
