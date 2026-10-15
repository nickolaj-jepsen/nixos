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
available at [docs/fireproof-options.md](docs/fireproof-options.md). Regenerate
it with `just docs` after changing any option declarations.

## Installing on a New Machine

The recommended flow is a **host-specific bootstrap ISO**: an install image with the new host's pre-rekeyed SSH key and a copy of this flake baked in. The target boots the USB and runs `bootstrap-install` — no GitHub roundtrip, no manual rekeying on the target, no `nixos-anywhere` fragility.

1. Create the host on your laptop (generates the SSH key, stages the new files, rekeys secrets with YubiKey):

   ```bash
   just new-host <hostname> <username>
   ```

   Creates `hosts/<hostname>/host.nix` (a card) and `secrets/hosts/<hostname>/`. Edit the card to enable features via `shared.fireproof.<feature>.enable = true` (and add `homeManager` tweaks). The host is discovered automatically — there is no `hosts/default.nix` registry to edit. Add the hostname to `trustedHosts` in `modules/system/ssh.nix` so the other hosts accept its SSH key.

2. (Optional) Pre-populate `hosts/<hostname>/disk-configuration.nix` with a `{ nixos.disko.devices = …; }` card if you already know the disk layout — otherwise the installer will pick a template interactively. Templates live in `hosts/_templates/disko/`.

3. Build a host-specific ISO (decrypts the SSH key via YubiKey, bakes it into the image at `~/.cache/bootstrap-iso/<hostname>.iso`, then purges the key's copies from the world-readable Nix store):

   ```bash
   just bootstrap-iso <hostname>
   ```

   It refuses to build until every secret the host declares is rekeyed, so re-run `just secret-rekey` after enabling features that add secrets. Push first: the installer re-attaches git history at the commit the ISO was built from.

4. Flash to USB (builds the ISO, flashes it, then deletes the ISO file):

   ```bash
   just bootstrap-flash <hostname> /dev/sdX
   ```

5. Boot the USB on the target. After autologin, the MOTD shows the next steps:

   ```bash
   nmtui              # connect WiFi (skip if wired)
   bootstrap-install  # interactive: picks disk, prompts for LUKS, installs
   ```

   The installer:
   - Keeps the host's existing disko layout (any `hosts/<hostname>/*.nix` defining `disko.devices`), otherwise prompts to pick a template and substitutes the chosen disk.
   - Regenerates `facter.json` if missing, prompts before overwriting an existing one, and wires it in with a `facter.nix` card if no host file references it.
   - Lists every disk it will wipe (path, size, model) before the final confirmation, and prompts for the LUKS passphrase only if the layout uses LUKS.
   - Places the host SSH key on the target before activation so agenix can decrypt secrets (including the user password) during install.
   - Copies the (possibly modified) flake into `~/nixos` on the installed system and fetches the repo's git history under it, so any live-generated configs show up in `git status` after first boot.

6. Reboot, then on the target:

   ```bash
   cd ~/nixos && git status   # new host files are staged; commit and push them
   ```

   Then wipe or reflash the USB stick: it still holds the host's private SSH key.

7. (Optional, LUKS hosts) Enroll the TPM2 for passwordless boot. This skips the
   LUKS passphrase prompt in initrd (~5–7s faster boot). The systemd initrd
   already ships TPM2 support, so no config change is needed — only this on-disk
   enrollment:

   ```bash
   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
     /dev/disk/by-partlabel/disk-main-luks
   ```

   > [!WARNING]
   > Security trade-off: with Secure Boot disabled,
   > a powered-off stolen _machine_ boots straight in (a stolen _drive_ is still
   > protected). For a middle ground add `--tpm2-with-pin=yes` to require a short
   > PIN. Roll back with `systemd-cryptenroll --wipe-slot=tpm2 <device>`.

> [!TIP]
> Upload the host pubkey (`secrets/hosts/<hostname>/id_ed25519.pub`) to GitHub to pull/push directly from the new host.

### Alternative: remote install via nixos-anywhere

If the target is already booted into a Linux environment with SSH access (cloud VM, recovery shell), you can install over the network instead:

```bash
just deploy-remote <hostname> user@remote
```

This uses `nixos-anywhere` and is convenient when it works, but is fragile on flaky networks or hosts that auto-reboot during kexec. Prefer the bootstrap ISO for physical machines. The generic ISO (`nixosConfigurations.bootstrap`) makes a suitable target: it allows root SSH with the password `nixos`. Host-specific bootstrap ISOs run no SSH server.

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
