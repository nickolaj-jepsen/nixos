# NixOS Configuration - AI Assistant Instructions

## Architecture Overview

This is a **NixOS flake-based configuration** managing multiple hosts (desktop, laptop, homelab, work, WSL) with:

- **flake-parts** for modular flake organization
- **home-manager** integrated via `fireproof.home-manager` option (not standalone)
- **agenix + agenix-rekey** for YubiKey-based secret management
- **disko** for declarative disk partitioning

### Module Structure

```
modules/
├── base/        # Core: fireproof options, secrets, home-manager integration
├── desktop/     # Desktop environment (niri WM, greetd, audio, fonts)
├── homelab/     # Self-hosted services (nginx, postgres, arr stack, etc.)
├── programs/    # User applications (ghostty, neovim, vscode, etc.)
└── system/      # System config (boot, networking, ssh, tailscale)
```

### Host Configuration Pattern

Each host in `hosts/<hostname>/` sets `fireproof.*` options to enable feature groups:

```nix
# hosts/desktop/default.nix
config.fireproof = {
  hostname = "desktop";
  username = "nickolaj";
  desktop.enable = true;   # Enables all desktop modules
  work.enable = true;      # Enables work-related programs
  dev.enable = true;       # Enables development tools
};
```

### Key Pattern: Feature Modules with `lib.mkIf`

Modules conditionally apply based on `fireproof.*` flags:

```nix
# Module pattern - check enabling flag first
{config, lib, ...}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    # Configuration only applied when desktop is enabled
  };
}
```

### Home Manager Integration

Use `fireproof.home-manager` instead of `home-manager.users.<user>`:

```nix
# Correct: Uses fireproof wrapper
fireproof.home-manager = {
  programs.ghostty.enable = true;
};

# Incorrect: Don't use directly
home-manager.users.nickolaj = { ... };
```

## Developer Commands

All operations use **just** - run `just` for command list:

```bash
just switch              # Rebuild current host
just switch homelab 10.0.0.11  # Deploy to remote host
just build-system desktop      # Build without switching
just diff                # Compare changes before switching

just secret-edit <name>  # Edit encrypted secret
just secret-rekey        # Rekey after adding hosts/secrets
just new-host <hostname> <user>  # Bootstrap new host config
```

## Secret Management

Secrets use **agenix-rekey** with YubiKey master identity:

- Global secrets: `secrets/*.age`
- Host-specific: `secrets/hosts/<hostname>/` (includes rekeyed secrets in `.rekey/`)
- Reference secrets via `config.age.secrets.<name>.path`

```nix
# Declaring a secret in a module
age.secrets.my-secret.rekeyFile = ../../secrets/hosts/homelab/my-secret.age;

# Using the decrypted path
services.myapp.environmentFile = config.age.secrets.my-secret.path;
```

## Code Style

- **Formatter**: `nix fmt` (alejandra + deadnix + statix)
- **nixpkgs-unstable**: Available as `pkgsUnstable` in module arguments
- **Theme colors**: Flexoki palette defined in README.md - use consistent HSL/Hex values

## Common Patterns

### Adding a new program module

1. Create `modules/programs/myapp.nix`
2. Guard with appropriate enable flag
3. Import in `modules/programs/default.nix`

```nix
# modules/programs/myapp.nix
{config, lib, pkgs, ...}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = [pkgs.myapp];
    fireproof.home-manager.programs.myapp = { ... };
  };
}
```

### Adding a homelab service

1. Create `modules/homelab/myservice.nix`
2. Guard with `lib.mkIf config.fireproof.homelab.enable`
3. Add nginx virtualHost for HTTPS proxy
4. Import in `modules/homelab/default.nix`
5. Update `glance.nix` for dashboard link

### Hardware config

Use `just factor <hostname>` to generate `facter.json` for hardware detection (replaces nixos-generate-config).
