# NixOS Configuration

Personal NixOS configuration using flakes, home-manager, and agenix for secret management.

## Quick Start

All common tasks are managed via `just`. Run `just` to see available commands.

### System Operations

```bash
# Rebuild and switch to new configuration
just switch

# Rebuild and switch a specific host
just switch desktop

# Try out configuration without making it permanent (reverts on reboot)
just test

# Apply on next boot
just boot

# Build without switching
just build-system

# Update flake inputs
just update

# Compare current system with configuration
just diff

# Format configuration files
just fmt

# Validate configuration (flake check)
just check

# Maintenance: Collect garbage and delete old generations
just gc
```

### Remote Deployment

```bash
# Deploy to a remote host (via nixos-rebuild --target-host)
just switch hostname user@remote

# Fresh install on a new machine (via nixos-anywhere)
just deploy-remote hostname user@remote

# Generate hardware configuration for a remote host
just factor hostname user@remote
```

### Tools & Debugging

```bash
# Open nix repl with flake loaded
just repl

# List system generations/history
just history

# Visualize dependency tree
just tree

# Build an install ISO for a specific host
just iso hostname

# Generate the fireproof.* options reference (docs/fireproof-options.md)
just docs
```

## Options Reference

This config exposes a custom `fireproof.*` options namespace. A generated
Markdown reference — descriptions, types, defaults, and declaration links — is
available at [docs/fireproof-options.md](docs/fireproof-options.md). Regenerate
it with `just docs` after changing any option declarations.

The Android (nix-on-droid) `phone` host has its own guide:
[docs/android.md](docs/android.md).

## Installing on a New Machine

The recommended flow is a **host-specific bootstrap ISO**: an install image with the new host's pre-rekeyed SSH key and a copy of this flake baked in. The target boots the USB and runs `bootstrap-install` — no GitHub roundtrip, no manual rekeying on the target, no `nixos-anywhere` fragility.

1. Create the host on your laptop (generates the SSH key, rekeys secrets with YubiKey):

   ```bash
   just new-host <hostname> <username>
   ```

   Creates `hosts/<hostname>/host.nix` (a card) and `secrets/hosts/<hostname>/`. Edit the card to enable features via `shared.fireproof.<feature>.enable = true` (and add `homeManager` tweaks). The host is discovered automatically — there is no `hosts/default.nix` registry to edit.

2. (Optional) Pre-populate `hosts/<hostname>/disk-configuration.nix` if you already know the disk layout — otherwise the installer will pick a template interactively. Templates live in `hosts/_templates/disko/`.

3. Build a host-specific ISO (decrypts the SSH key via YubiKey, bakes it into the image):

   ```bash
   just bootstrap-iso <hostname>
   ```

4. Flash to USB:

   ```bash
   just bootstrap-flash <hostname> /dev/sdX
   ```

5. Boot the USB on the target. After autologin, the MOTD shows the next steps:

   ```bash
   nmtui              # connect WiFi (skip if wired)
   bootstrap-install  # interactive: picks disk, prompts for LUKS, installs
   ```

   The installer:
   - Uses `hosts/<hostname>/disk-configuration.nix` if present, otherwise prompts to pick a template and substitutes the chosen disk.
   - Regenerates `facter.json` if missing, prompts before overwriting an existing one.
   - Prompts for the LUKS passphrase only if the disko config uses LUKS.
   - Places the host SSH key on the target before activation so agenix can decrypt secrets (including the user password) during install.
   - Copies the (possibly modified) flake into `~/<user>/nixos` on the installed system, so any live-generated configs show up as `git diff` after first boot.

6. Reboot, then on the target:

   ```bash
   cd ~/nixos && git status   # review live-generated configs, commit if desired
   ```

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

This uses `nixos-anywhere` and is convenient when it works, but is fragile on flaky networks or hosts that auto-reboot during kexec. Prefer the bootstrap ISO for physical machines.

## Secret Management

Secrets are managed with [agenix](https://github.com/ryantm/agenix) + [agenix-rekey](https://github.com/oddlama/agenix-rekey), using a YubiKey as the master identity.

### Structure

```
secrets/
├── yubikey-identity.pub    # Master encryption key
├── *.age                   # Global secrets
└── hosts/<hostname>/
    ├── id_ed25519.pub      # Host public key
    ├── id_ed25519.age      # Host private key (encrypted)
    ├── .rekey/             # Rekeyed nixos (root) secrets
    └── .rekey-hm/          # Rekeyed home-manager (user) secrets
```

### Commands

```bash
# Edit a secret
just secret-edit <secret-name>

# Rekey all secrets (after adding hosts/secrets)
just secret-rekey

# Decrypt a file to stdout
just decrypt <file.age>

# Run rage with yubikey
just age -e <file> -o <output.age>
```

## Development

### Development Shell

A Nix development shell is available with useful tools for working on this configuration:

```bash
# Enter the development shell
nix develop
```

### Formatting

Code is formatted using `treefmt-nix` with:

- **alejandra** - Nix formatter
- **deadnix** - Remove unused Nix code
- **statix** - Nix linter
- **prettier** - JSON/YAML/Markdown
- **just** - Justfile formatter
- **fish_indent** - Fish scripts

```bash
nix fmt
```

### Useful Tools

```bash
# Explore dependency tree
just tree

# Generate Nix fetcher from URL
just nurl https://github.com/owner/repo
```

## Theme

Heavily inspired by / stolen from [Flexoki](https://stephango.com/flexoki)

| Name        | Hex     |
| ----------- | ------- |
| bg          | #1C1B1A |
| bg-alt      | #282726 |
| fg          | #DAD8CE |
| fg-alt      | #B7B5AC |
| muted       | #878580 |
| ui          | #343331 |
| ui-alt      | #403E3C |
| black       | #100F0F |
| accent      | #CF6A4C |
| red         | #D14D41 |
| red-alt     | #AF3029 |
| orange      | #DA702C |
| orange-alt  | #BC5215 |
| yellow      | #D0A215 |
| yellow-alt  | #AD8301 |
| green       | #879A39 |
| green-alt   | #66800B |
| cyan        | #3AA99F |
| cyan-alt    | #24837B |
| blue        | #4385BE |
| blue-alt    | #205EA6 |
| purple      | #8B7EC8 |
| purple-alt  | #5E409D |
| magenta     | #CE5D97 |
| magenta-alt | #A02F6F |
| white       | #DAD8CE |
| white-alt   | #F2F0E5 |
