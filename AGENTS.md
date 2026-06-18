## Intrepetring tasks

When you're asked to update a configuration, the user usually referes to update the config in this nixos configuration, eg claude-code config should be updated in modules/programs/claude-code and vscode in /home/nickolaj/nixos/modules/programs/vscode

## Commands

All operations use the `just` command runner. Run `just` to see all commands.

```bash
just switch              # Rebuild and switch to new config
just switch desktop      # Rebuild specific host
just test                # Apply temporarily (reverts on reboot)
just boot                # Apply on next boot
just build-system        # Build without switching
just home-build <h>      # Build a home-manager (class="home") host, e.g. dev-ao
just home-switch <h>     # Activate it on the host; push to remote: home-switch dev-ao nij@dev.ao
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

This is a NixOS flake-based configuration managing 8 hosts (6 NixOS + 1 standalone home-manager `dev-ao` + 1 nix-on-droid `phone`) with a custom `fireproof.*` options namespace.

### Structure

```
hosts/                    # Per-host configs; <h>/host.nix = toggle+fact card; default.nix = builder + discovery
lib/                      # Shared helpers (fpLib) + mkHome.nix (standalone home-manager builder)
modules/                  # Feature leaves; each self-gates on a fireproof.* option (nested + cascading)
  ├── base/               #   always-on: fireproof.nix + theme.nix (central option decls),
  │                       #   nix, gc, secrets, hm-secrets
  ├── system/             #   host/OS leaves: boot, networking, user, ssh, yubikey, wsl, keyd,
  │                       #   + hardware hygiene (smartd, thermald, zram, journald, btrfs-scrub, battery, networkd)
  ├── desktop/            #   niri + dms + greetd + desktop apps; nvidia, snapcast, 0xcb-media
  ├── programs/           #   CLI + GUI programs (claude-code, vscode, zed, firefox, git, fish, …)
  ├── homelab/            #   server services (arr, jellyfin, nginx, …)
  └── scripts/            #   writeShellApplication helpers (always-on)
installer/                # Installer ISO builder — owns nixosConfigurations.bootstrap{,-<host>}
                          #   (not a host: a self-contained corner, direct nixosSystem build)
secrets/                  # agenix-encrypted secrets with YubiKey
                          #   <host>/.rekey = nixos secrets, <host>/.rekey-hm = HM secrets
```

### Modules are dendritic (`flake.modules`), gated by toggles

Every `.nix` file under `modules/` is a **dendritic flake-parts module** that
self-declares its outputs (not a bare NixOS module).
[`import-tree`](https://github.com/vic/import-tree) (at the flake level in
`flake.nix`) auto-collects **every** such file into
`flake.modules.{nixos,homeManager}.<name>` — no hand-maintained `imports = [ … ]`.

The host builder (`hosts/default.nix`) imports **every** leaf into **every** host
(routing nixos halves into the system, homeManager halves into that user's
home-manager). A leaf applies only when its **toggle** is on, so each feature leaf
**self-gates** its `config` with `lib.mkIf config.fireproof.<feature>.enable`:

```nix
# modules/desktop/foo.nix
{
  flake.modules.nixos.foo = {config, lib, pkgs, ...}: {
    config = lib.mkIf config.fireproof.desktop.enable {
      environment.systemPackages = [pkgs.foo];
    };
  };
  flake.modules.homeManager.foo = {config, lib, ...}: {
    config = lib.mkIf config.fireproof.desktop.enable { … };   # gate BOTH halves
  };
}
```

The **folder** a leaf lives in is just organization — it has no semantic effect;
the gate is whatever `fireproof.*` option the leaf's `mkIf` reads. By convention a
folder clusters leaves that share a gate: `desktop/*` gate `desktop.enable` (or a
`desktop.<sub>.enable` child), `homelab/*` gate `homelab.enable`, `programs/*` gate
the relevant capability (`desktop.enable && dev.enable` for the GUI IDEs,
`dev.<tool>.enable` for CLI dev tools, `desktop.<app>.enable` for desktop apps). The
always-on leaves — `base/*`, `scripts/*`, and the baseline `programs/*` (git, fish,
neovim, docker, …) and `system/*` (boot, networking, user, …) — are **ungated**; the
hardware-hygiene `system/*` leaves gate `hardware.physical`/`hardware.zram`, and
`system/battery.nix` gates `hardware.battery`.

### Options are nested + cascading

`fireproof.*` options nest and **cascade**: a child enable defaults to its parent,
so a host sets the parent toggle and only overrides exceptions. `desktop.chromium.enable`
defaults to `desktop.enable`; `dev.{intellij,clickhouse,
playwright}.enable` default to `dev.enable`; `hardware.physical` defaults to
`!wsl.enable`, `hardware.zram` to `hardware.physical`, and `hardware.{battery,wifi,
dimmableBacklight}` to `hardware.laptop`. Opt-in extras (`desktop.{bambu-studio,
google-chrome,snapcast,oxcbMedia}.enable`, `hardware.nvidia.enable`) default **off**.
So minilab — a desktop host that skips chromium and the IDEs — sets
`desktop.enable = true` then overrides `desktop.chromium.enable = false` and
`dev.{intellij,clickhouse,playwright}.enable = false`. This cascade IS the lightweight
composition layer (no separate bundle/aspect system). All these options are declared
centrally in `modules/base/fireproof.nix` (theme in `modules/base/theme.nix`), emitted
to both module classes.

The module **name** (`flake.modules.<class>.<name>`) must be **globally unique** —
it is one flat namespace, so a duplicate silently deep-merges (e.g.
`modules/dev/postgres.nix` is named `postgres-cli` to avoid colliding with
`modules/homelab/postgres.nix`'s `postgres`).

Gotchas:

- **`lib.mkIf` gates `config` ONLY.** Never put `imports` or `options` inside the
  `mkIf` — they must stay at the top level (siblings of `config`). A leaf that
  `imports` a third-party module (e.g. `modules/desktop/dms/default.nix`,
  `modules/desktop/0xcb-media.nix`) imports it on **every** host; only its `config`
  is toggle-gated, so such modules must be inert when their feature is disabled.
- **`_`-prefixed paths are skipped** by import-tree and by the host collector
  (helper files, page fragments): `modules/homelab/glance/_home-page.nix`,
  `modules/homelab/glance/_work-page.nix`.
- **Per-host files** live in the host's directory (`hosts/<h>/`) and are imported
  only for that host. Each is a **card** — same shape as `host.nix` — with its
  NixOS config in a `nixos` bucket (see "Host cards").
- Shared cross-class options live in `modules/base/fireproof.nix` (theme in
  `modules/base/theme.nix`).

### Host cards (`fireproof.*`)

A host enables **toggles**, not aspects, via a `hosts/<host>/host.nix` **card**:
`{ shared = { fireproof.<feature>.enable = true; … }; homeManager = { … }; }`.
`shared` is a module merged into BOTH the nixos and the home-manager evals (the
no-bridge fact flow — no osConfig), so a toggle set there is visible to both
classes; `homeManager` is the host's HM tweaks. The fleet is **discovered** — any
`hosts/<name>/` directory containing a `host.nix` is a host (`hosts/default.nix`);
there is no central registry.

**Every** `.nix` file in a host dir is a card of the shape `{ class?; shared?;
nixos?; homeManager?; }` — not just `host.nix`. The collector (`hosts/default.nix`)
asserts it: a bare NixOS module (a function, or an attrset with any other top-level
key) throws, pointing you at the `nixos` bucket. That `nixos` bucket is the
per-host analog of a dendritic leaf's `flake.modules.nixos.<name>`. Buckets are
merged across all cards in the dir, so config/facts/HM can live in `host.nix` or
any sibling — e.g. `system.nix` (nixos-only settings), `monitors.nix`
(`shared.fireproof.monitors`), or a feature co-located with its config (minilab's
`snapcast.nix` carries both `shared.fireproof.desktop.snapcast.enable = true` and the
capture config in its `nixos` bucket).

A host's **class** is the one scalar a card may carry: `class = "nixos"` (the
default), `class = "home"`, or `class = "droid"`. It is read pre-eval and routes
the WHOLE host — `nixos` hosts build via `nixpkgs.lib.nixosSystem` into
`nixosConfigurations.<h>`; `home` hosts build via `lib/mkHome.nix` (standalone
home-manager, no NixOS eval) into `homeConfigurations.<h>`; `droid` hosts build
via the inline `mkDroid` (`inputs.nix-on-droid.lib.nixOnDroidConfiguration`,
aarch64, no NixOS eval) into `nixOnDroidConfigurations.<h>`. Both `home` and
`droid` hosts assert their `nixos` bucket empty. A `droid` host carries its
nix-on-droid system config in a `droid` bucket (the 5th card key — `user.shell`,
`system.stateVersion`, `time.timeZone`, …) and reuses the `homeManager` leaves via
nix-on-droid's embedded home-manager (its `shared`/`homeManager` buckets feed that
HM eval, where `fireproof.*` is declared — NOT the n-o-d system eval); n-o-d forces
`home.username`/`homeDirectory` from `config.user.*`, so `mkDroid` sets neither. The
routable set lives in `validClasses` (`hosts/default.nix`) — a typo throws; adding
`darwin` later is a value there + a `buildDarwin` + a `darwinConfigurations` emit.
`config.flake.hostNames` (the installer's bootstrap fan-out) is the **nixos** hosts
only. Examples: `hosts/dev-ao/host.nix` is a headless home-manager-only host
(`class = "home"`); `hosts/phone/host.nix` is a nix-on-droid Android host
(`class = "droid"`), activated on-device with `just droid-switch` (`nix-on-droid
switch --flake .#phone`).

A "fact" is just a `fireproof.*` option value set in a `shared` card — the toggle
`fireproof.<feature>.enable = true` IS the fact that gates the feature's leaves;
the module system merges these with real precedence. **Every toggle must be
declared in both module classes** (it is, in `modules/base/fireproof.nix`, emitted
to both): a toggle set via `shared` reaches both evals, so a class-only declaration
would throw on an undeclared option in the other eval. The cascade defaults (see
"Options are nested + cascading") are the composition layer — a host sets the parent
toggles and overrides exceptions, rather than listing every leaf.

Shared, cross-class options (`fireproof.{hostname,username,monitors,hardware.*,
desktop.*,dev.*,…}` plus the feature `*.enable` toggles) are declared once in
`modules/base/fireproof.nix` (theme palette in `modules/base/theme.nix`), both
emitted to both module classes.

### Home Manager

Author a feature's home-manager half as `flake.modules.homeManager.<name>`,
reading `config.fireproof.*` locally (facts are injected). It evaluates both
embedded (per host, via the NixOS home-manager module) and standalone
(`lib/mkHome.nix`, `osConfig = null`) — the standalone path is how a
`class = "home"` host builds. The `dev-ao` home host doubles as the standalone-HM
guard: `home-check.nix` builds `homeConfigurations.dev-ao.activationPackage` in
`just check`, so an HM half that starts reading `osConfig` (or a non-shared
option) fails CI, not just a future deploy. For embedded (nixos) hosts the host
builder (`hosts/default.nix`) defines `home-manager.users.<user>` (the user read
from `config.fireproof.username`) and routes **all** homeManager leaves (each
self-gates via `lib.mkIf`) — plus the host card's `shared` and `homeManager`
buckets — into its `sharedModules`. There is no `fireproof.home-manager` alias.

### Theme System

Colors in `modules/base/theme.nix` as `config.fireproof.theme.colors.*`:

```nix
let c = config.fireproof.theme.colors;
in {
  background = c.bg;        # Without # prefix
  border = "#${c.accent}";  # Add # when needed
}
```

### Gate every feature leaf with mkIf

A leaf is imported into every host, so it must **gate its own `config`** with
`lib.mkIf config.fireproof.<feature>.enable` — otherwise it applies everywhere:

```nix
# modules/desktop/foo.nix → active only where fireproof.desktop.enable is true
{
  flake.modules.nixos.foo = {config, lib, pkgs, ...}: {
    config = lib.mkIf config.fireproof.desktop.enable {
      environment.systemPackages = [pkgs.foo];
    };
  };
}
```

Gate **both** halves of a dual-class leaf on the same toggle. Keep `options` and
`imports` OUTSIDE the `mkIf` (it gates `config` only). The always-on leaves
(`base/*`, `scripts/*`, and the baseline `programs/*` and `system/*`) are the
exception — they apply unconditionally, so no gate.

Intra-module conditionals on other `fireproof.*` values (e.g.
`lib.optional config.fireproof.hardware.battery …`) nest fine inside the feature
gate — those are parameters.

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

Leaf modules, host files, and overlays are **auto-imported** (see "Modules are
dendritic") — create the file in the right directory, no `imports` list to edit.

- **New program / feature (leaf)**: Create the file under the relevant folder —
  `modules/<group>/<name>.nix` (`programs/` for apps, `desktop/` for desktop bits,
  `system/` for OS/hardware, `homelab/` for services). Declare
  `flake.modules.nixos.<name>` and/or `flake.modules.homeManager.<name>`, gating each
  half's `config` with `lib.mkIf config.fireproof.<feature>.enable` (reuse the
  capability gate, e.g. `desktop.enable`, or a nested child). For a **new** toggle,
  add a `fireproof.<feature>.enable = lib.mkEnableOption "…";` (or a cascading
  `lib.mkOption { default = config.fireproof.<parent>.enable; }`) to
  `modules/base/fireproof.nix` (declared in both classes automatically), and enable
  it per host via `shared.fireproof.<feature>.enable = true`. For a homelab service
  also add a dashboard link in `modules/homelab/glance/_home-page.nix`.
- **New always-on leaf**: Put it in `base/`, `scripts/`, or as an ungated
  `programs/`/`system/` leaf and leave it ungated — those apply to every host.
- **New host**: Run `just new-host <hostname> <username>` — it drops a
  `hosts/<hostname>/host.nix` card; enable features via
  `shared.fireproof.<feature>.enable = true` (and add `homeManager` tweaks) to
  taste. The host is **discovered automatically** (the `host.nix` is the marker);
  no `hosts/default.nix` edit. Per-host files (`system.nix`,
  `disk-configuration.nix`, `monitors.nix`, …) go in the host directory as
  **cards** — NixOS config under a `nixos` bucket. To install
  on physical hardware,
  build a host-specific bootstrap ISO with `just bootstrap-iso <hostname>` and
  flash with `just bootstrap-flash <hostname> /dev/sdX` — the ISO bakes in the
  host SSH key + a copy of this flake, target boots and runs `bootstrap-install`.
- **New disko template**: Add `hosts/_templates/disko/<name>.nix` with `device = "@@DISK@@";` as the sentinel. The bootstrap installer offers any template found here when no `disk-configuration.nix` exists yet.
- **New script**: Use `pkgs.writeShellApplication`, include `set -euo pipefail`
- **New overlay**: Create `overlays/<name>.nix` (auto-imported), and add update instructions (if needed) in `.github/workflows/update-overlays.md` a [GitHub Agentic Workflows file](https://github.com/github/gh-aw). Then recompile: `gh aw compile update-overlays`

## Secrets

Managed with agenix-rekey + YubiKey. Host keys in `secrets/hosts/<hostname>/id_ed25519.{pub,age}`.

> **Droid caveat:** agenix-rekey discovers nodes from `nixos`/`home` configs only,
> not `nixOnDroidConfigurations`, so a `droid` host's HM rekey node is invisible to
> `just secret-rekey`. Keep droid hosts secret-free (the `phone` deliberately
> declares zero `age.secrets` — only its `id_ed25519.pub` is committed, so the
> always-on `ssh`/`hm-secrets` leaves stay inert) until the droid nodes are
> explicitly registered as agenix-rekey nodes.

```bash
just secret-edit <name>  # Edit encrypted secret
just secret-rekey        # Rekey after adding hosts/secrets (touch YubiKey)
```

Two rekey stores per host, because `agenix rekey` deletes any file in a node's
`localStorageDir` that the node doesn't own — so the nixos and home-manager nodes
of one host **must not share a dir**:

- **`secrets/hosts/<h>/.rekey/`** — nixos secrets (`modules/base/secrets.nix`):
  `age.secrets.*` declared in a `flake.modules.nixos.*` half, decrypted by root.
- **`secrets/hosts/<h>/.rekey-hm/`** — home-manager secrets
  (`modules/base/hm-secrets.nix`): `age.secrets.*` declared in a
  `flake.modules.homeManager.*` half, decrypted during HM activation (as the user)
  via `~/.ssh/id_ed25519`. The `ssh-key` secret stays nixos-side because it _is_
  that identity (it can't decrypt itself). Both stores use the same `hostPubkey`,
  so the encrypted blobs are interchangeable.

## Maintaining This File

Update this file (AGENTS.md — CLAUDE.md just `@`-includes it) when making changes relevant to AI agents, such as:

- New just commands or workflows
- Changes to the module structure or `fireproof.*` options
- New patterns or conventions
