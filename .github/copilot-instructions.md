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
just update nixpkgs        # Update single input
just diff                  # Preview changes before switching
nix fmt                    # Format with alejandra, deadnix, statix
```

## Secret Management

Secrets use agenix + agenix-rekey with YubiKey master identity:

- Global secrets: `secrets/*.age`
- Per-host secrets: `secrets/hosts/<hostname>/`
- Host keys are in `secrets/hosts/<hostname>/id_ed25519.{pub,age}`
- Rekey after adding hosts/secrets: `just secret-rekey`

## Adding New Features

1. **New program**: Create `modules/programs/<name>.nix`, guard with `lib.mkIf config.fireproof.desktop.enable` or similar
2. **New homelab service**: Create `modules/homelab/<name>.nix`, add to `modules/homelab/default.nix` imports
3. **New host**: Run `just new-host <hostname> <username>`, then add to `hosts/default.nix`

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
