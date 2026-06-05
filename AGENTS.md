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
just docs                # Generate fireproof.* options reference -> docs/fireproof-options.md
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
lib/                      # Shared helpers (fpLib), available via specialArgs
modules/
  ├── base/              # Core: fireproof options, theme, secrets, overlays
  ├── system/            # Boot, networking, SSH, hardware, security
  ├── programs/          # User applications and dev tools
  ├── desktop/           # niri window manager, greetd, audio, fonts
  ├── homelab/           # Server services (arr, jellyfin, nginx, etc.)
  └── scripts/           # Utility shell scripts
secrets/                  # agenix-encrypted secrets with YubiKey
```

### Module Auto-Imports

Modules are **auto-imported** — there are no hand-maintained `imports = [ … ]`
lists. `hosts/default.nix` uses [`import-tree`](https://github.com/vic/import-tree)
to recursively pull in:

- every `.nix` file under `modules/` (for every host), and
- every `.nix` file in the host's own directory (e.g. `hosts/desktop/`).

So **dropping a `.nix` file into the tree is enough to wire it up** — no list to
edit. Each module gates itself with `lib.mkIf config.fireproof.<feature>.enable`,
so being imported everywhere is inert until enabled.

Conventions:

- **Non-module helper files** (functions called with `import ./x.nix {…}`, page
  fragments, etc.) must be **prefixed with `_`** so import-tree skips them — e.g.
  `modules/homelab/glance/_home-page.nix`, `hosts/bootstrap/_bake.nix`. Anything
  under a `_`-prefixed path is ignored.
- **Per-host files** live in that host's directory and are auto-imported only for
  that host.
- `default.nix` files are only needed when they hold real options/config; a
  `default.nix` that only listed imports has been removed.

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

### Shared Helpers (`lib/`)

`fpLib` is available via `specialArgs` and contains shared utility functions:

```nix
{fpLib, ...}: {
  services.nginx.virtualHosts."example.com" = fpLib.mkVirtualHost {
    port = 8080;
    websockets = true;  # optional, default false
    http2 = true;       # optional, default false
    host = "127.0.0.1"; # optional, default "127.0.0.1"
  };

  services.postgresql = fpLib.mkPostgresDB {
    name = "myservice";
    login = true;              # optional, default false — adds ensureClauses.login
    authentication = lib.mkAfter "..."; # optional, default null
  };
}
```

## Adding Features

Modules, host files, and overlays are **auto-imported** (see "Module
Auto-Imports") — just create the file in the right directory, no `imports` list to
edit.

- **New program**: Create `modules/programs/<name>.nix`. Auto-imported.
- **New homelab service**: Create `modules/homelab/<name>.nix` (auto-imported), add dashboard link in `modules/homelab/glance/_home-page.nix`.
- **New host**: Run `just new-host <hostname> <username>`, add to `hosts/default.nix`. Per-host files (`disk-configuration.nix`, `monitors.nix`, …) go in the host directory and are auto-imported. To install on physical hardware, build a host-specific bootstrap ISO with `just bootstrap-iso <hostname>` and flash with `just bootstrap-flash <hostname> /dev/sdX` — the ISO bakes in the host SSH key + a copy of this flake, target boots and runs `bootstrap-install`.
- **New disko template**: Add `hosts/_templates/disko/<name>.nix` with `device = "@@DISK@@";` as the sentinel. The bootstrap installer offers any template found here when no `disk-configuration.nix` exists yet.
- **New script**: Use `pkgs.writeShellApplication`, include `set -euo pipefail`
- **New overlay**: Create `overlays/<name>.nix` (auto-imported), and add update instructions (if needed) in `.github/workflows/update-overlays.md` a [GitHub Agentic Workflows file](https://github.com/github/gh-aw). Then recompile: `gh aw compile update-overlays`

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
