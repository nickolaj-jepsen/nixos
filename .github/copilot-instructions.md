# NixOS Configuration - Copilot Instructions

## Architecture Overview

This is a **NixOS flake-based configuration** using flake-parts, managing multiple hosts (desktop, laptop, work, homelab, desktop-wsl, bootstrap). The configuration uses a custom module system under `fireproof.*` options.

### Key Structural Patterns

- **Host definitions**: `hosts/<hostname>/default.nix` sets `fireproof.hostname`, `fireproof.username`, and feature flags
- **Module organization**: `modules/` contains themed directories (`base/`, `desktop/`, `programs/`, `homelab/`, `system/`, `scripts/`)
- **Host configuration flow**: `hosts/default.nix` defines `mkSystem` which imports all module directories plus the specific host

### The `fireproof` Options System

All custom options live under `fireproof.*`. Key options:

```nix
fireproof.hostname = "desktop";          # Required per host
fireproof.username = "nickolaj";         # Required per host
fireproof.desktop.enable = true;         # Enables niri + desktop modules
fireproof.homelab.enable = true;         # Enables server services
fireproof.work.enable = true;            # Work-related tools
fireproof.dev.enable = true;             # Development tools
```

### Home Manager Integration

Use `fireproof.home-manager` instead of `home-manager.users.<username>`:

```nix
# Correct pattern (from modules/programs/ghostty.nix)
fireproof.home-manager.programs.ghostty.enable = true;

# NOT: home-manager.users.nickolaj.programs...
```

### Theme System

Colors are defined in `modules/base/theme.nix` under `config.fireproof.theme.colors.*`. Access them as:

```nix
let c = config.fireproof.theme.colors;
in {
  background = c.bg;        # No # prefix in the option
  border = "#${c.accent}";  # Add # when needed
}
```

## Developer Workflow

Use `just` for all operations:

```bash
just switch                # Rebuild current host
just switch desktop <IP>   # Rebuild specific host
just test                  # Apply changes temporarily (nixos-rebuild test)
just boot                  # Apply changes on next boot
just update                # Update flake.lock
just diff                  # Preview changes before switching
just fmt                   # Format all files
just gc                    # Collect garbage (delete older than 7d)
just check                 # Validate configuration
just repl                  # Open nix repl with flake loaded
just factor                # Generate nixos-facter hardware config
just secret-edit <path>    # Edit an encrypted secret
```

### Safety Boundaries

**CRITICAL**: As an AI agent, you are **FORBIDDEN** from executing commands that permanently modify the system state or perform remote deployments.

- **DO NOT** run `just switch` or `just boot`.
- **DO NOT** run `just switch <hostname> <target>`.
- Use `just test` or `just build-system` if you need to verify that a configuration builds successfully.
- **ALWAYS** run `just fmt` after modifying files and before finishing your task to ensure consistent code style.

## Secret Management

Secrets use agenix + agenix-rekey with YubiKey master identity:

- Global secrets: `secrets/*.age`
- Per-host secrets: `secrets/hosts/<hostname>/`
- Host keys are in `secrets/hosts/<hostname>/id_ed25519.{pub,age}`
- Rekey after adding hosts/secrets: `just secret-rekey`

## Adding New Features

1. **New program**: Create `modules/programs/<name>.nix`, guard with `lib.mkIf config.fireproof.desktop.enable` or similar
2. **New homelab service**: Create `modules/homelab/<name>.nix`, add to `modules/homelab/default.nix` imports, and **add a link to the dashboard in `modules/homelab/glance.nix`**
3. **New host**: Run `just new-host <hostname> <username>`, then add to `hosts/default.nix`
4. **New script**: Always include `set -euo pipefail` at the start of bash scripts.

## Common Patterns

### Conditional Module Loading

```nix
{config, lib, ...}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    # Desktop-only configuration
  };
}
```

### Using Unstable Packages

`pkgsUnstable` is available via `specialArgs` when packages need bleeding-edge versions.

### Hardware Config

Use `facter.reportPath = ./facter.json;` in host config; generate with `just factor <hostname>`.
