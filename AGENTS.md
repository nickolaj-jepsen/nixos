## Intrepetring tasks

When you're asked to update a configuration, the user usually referes to update the config in this nixos configuration, eg claude-code config should be updated in modules/programs/claude-code.nix and vscode in /home/nickolaj/nixos/modules/programs/vscode

## Commands

All operations use the `just` command runner. Run `just` to see all commands.

```bash
just switch              # Rebuild and switch to new config
just switch desktop      # Rebuild specific host
just test                # Apply temporarily (reverts on reboot)
just boot                # Apply on next boot
just build-system        # Build without switching
just diff                # Preview changes vs current system
just update              # Update flake.lock
just fmt                 # Format all files (ALWAYS run before finishing)
just check               # Full flake check (slow, use sparingly)
just repl                # Open nix repl with flake loaded
just why-depends <pkg>   # Show why a package is in the closure
```

**Safety**: Do not run `just switch` or `just boot` without explicit user approval. Use `just test` or `just build-system` to verify builds.

## Architecture

This is a NixOS flake-based configuration managing 7 hosts with a custom `fireproof.*` options namespace.

### Structure

```
hosts/                    # Per-host configs (desktop, laptop, work, homelab, etc.)
  └── default.nix        # mkSystem helper and host definitions
modules/
  ├── base/              # Core: fireproof options, theme, secrets, overlays
  ├── system/            # Boot, networking, SSH, hardware, security
  ├── programs/          # User applications and dev tools
  ├── desktop/           # niri window manager, greetd, audio, fonts
  ├── homelab/           # Server services (arr, jellyfin, nginx, etc.)
  └── scripts/           # Utility shell scripts
secrets/                  # agenix-encrypted secrets with YubiKey
```

### Custom Options (`fireproof.*`)

Defined in `modules/base/fireproof.nix`:

```nix
fireproof.hostname = "desktop";          # Required
fireproof.username = "nickolaj";         # Required
fireproof.desktop.enable = true;         # Desktop environment (niri)
fireproof.homelab.enable = true;         # Server services
fireproof.work.enable = true;            # Work tools
fireproof.dev.enable = true;             # Dev tools
fireproof.hardware.laptop = true;        # Laptop features
```

### Home Manager

Use `fireproof.home-manager` instead of `home-manager.users.<username>`:

```nix
fireproof.home-manager.programs.ghostty.enable = true;
fireproof.home-manager.home.sessionVariables = {...};
```

### Theme System

Colors in `modules/base/theme.nix` as `config.fireproof.theme.colors.*`:

```nix
let c = config.fireproof.theme.colors;
in {
  background = c.bg;        # Without # prefix
  border = "#${c.accent}";  # Add # when needed
}
```

### Conditional Modules

```nix
{config, lib, ...}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    # Desktop-only config
  };
}
```

### Unstable Packages

`pkgs.unstable` is available via an overlay on the `pkgs` set:

```nix
{pkgs, ...}: {
  environment.systemPackages = [pkgs.unstable.somePackage];
}
```

## Adding Features

- **New program**: Create `modules/programs/<name>.nix`
- **New homelab service**: Create `modules/homelab/<name>.nix`, add to `modules/homelab/default.nix` imports, add dashboard link in `modules/homelab/glance.nix`
- **New host**: Run `just new-host <hostname> <username>`, add to `hosts/default.nix`
- **New script**: Use `pkgs.writeShellApplication`, include `set -euo pipefail`
- **New overlay**: Create `overlays/<name>.nix`, add to `overlays/default.nix` imports, and add update instructions (if needed) in `.github/workflows/update-overlays.md` a [GitHub Agentic Workflows file](https://github.com/github/gh-aw). Then recompile: `gh aw compile update-overlays`

## Secrets

Managed with agenix + YubiKey. Host keys in `secrets/hosts/<hostname>/id_ed25519.{pub,age}`.

```bash
just secret-edit <name>  # Edit encrypted secret
just secret-rekey        # Rekey after adding hosts
```

## Maintaining This File

Update CLAUDE.md when making changes relevant to AI agents, such as:

- New just commands or workflows
- Changes to the module structure or `fireproof.*` options
- New patterns or conventions
