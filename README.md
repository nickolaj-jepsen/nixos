# NixOS Configuration

Personal NixOS configuration using flakes, home-manager, and agenix for secret management.

## Quick Start

All common tasks are managed via `just`. Run `just` to see available commands.

### System Operations

```bash
# Rebuild and switch to new configuration (current host)
just switch

# Rebuild a specific host
just switch desktop

# Update flake inputs
just update

# Update a specific input
just update nixpkgs

# Build without switching
just build-system

# Compare changes before switching
just diff
```

### Remote Deployment

```bash
# Deploy to a remote host
just switch hostname user@remote

# Fresh install on a new machine
just deploy-remote hostname user@remote
```

### Bootstrap ISO

```bash
# Build bootable USB installer
just bootstrap-iso

# Flash to USB drive
just bootstrap-flash /dev/sdX
```

## Adding a New Host

1. Run the new-host command:

   ```bash
   just new-host <hostname> <username>
   ```

   This creates:
   - `hosts/<hostname>/` directory
   - `secrets/hosts/<hostname>/` with SSH keys

2. Add host configuration in `hosts/default.nix`:

   ```nix
   <hostname> = mkSystem {
     hostname = "<hostname>";
     username = "<username>";
   };
   ```

3. Create required files in `hosts/<hostname>/`:
   - `configuration.nix` - Main host config
   - `disk-configuration.nix` - Disk layout (for disko)
   - Other host-specific modules as needed

4. Generate hardware config:

   ```bash
   just factor <hostname>
   # Or for remote:
   just factor <hostname> user@remote
   ```

5. Rekey secrets:
   ```bash
   just secret-rekey
   ```

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
    └── .rekey/             # Rekeyed secrets for this host
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
