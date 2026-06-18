## Intrepetring tasks

When you're asked to update a configuration, the user usually referes to update the config in this nixos configuration, eg claude-code config should be updated in modules/cli/claude-code and vscode in /home/nickolaj/nixos/modules/gui-dev/vscode

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

This is a NixOS flake-based configuration managing 6 hosts with a custom `fireproof.*` options namespace.

### Structure

```
hosts/                    # Per-host configs; <h>/host.nix = aspect+fact card; default.nix = builder + discovery
lib/                      # Shared helpers (fpLib) + the aspect resolver (aspects.nix)
aspects.nix               # Bundle DAG (pure adjacency) — the composition graph
modules/                  # ONE FOLDER PER ASPECT: the folder a file is in IS its membership
  ├── <name>.nix          #   a file directly under modules/ = a single-leaf aspect
  │                       #   (nvidia, wsl, docker, chromium, clickhouse, intellij, …)
  ├── nix/ system/ cli/   #   always-on aspects (pulled in by base.includes)
  │   secrets/ scripts/
  ├── desktop/ dev/ gui-dev/ gui-work/   # capability aspects (desktop = niri + dms + apps)
  ├── physical/ laptop/   #   hardware aspects
  └── homelab/            #   server services (arr, jellyfin, nginx, …)
installer/                # Installer ISO builder — owns nixosConfigurations.bootstrap{,-<host>}
                          #   (not a host: a self-contained corner, direct nixosSystem build)
secrets/                  # agenix-encrypted secrets with YubiKey
                          #   <host>/.rekey = nixos secrets, <host>/.rekey-hm = HM secrets
```

### Modules are dendritic (`flake.modules`), folder = aspect

Every `.nix` file under `modules/` is a **dendritic flake-parts module** that
self-declares its outputs (not a bare NixOS module). **The folder it lives in is
its aspect** — there is no per-file membership tag:

```nix
# modules/desktop/foo.nix  → aspect "desktop" (the folder); no tag line needed
{
  flake.modules.nixos.foo = {config, pkgs, ...}: { … };         # nixos half (optional)
  flake.modules.homeManager.foo = {config, pkgs, ...}: { … };   # home-manager half (optional)
}
```

How membership is derived: the `wrapAspect` stamper in `flake.nix` reads each
file's declared module **name(s)** out of `flake.modules.*` and stamps
`flake.aspectTags.<name> = [<aspect>]`, where `<aspect>` is the **first path
segment under `modules/`** (or the **filename stem** for a file placed directly in
`modules/`). The module **name** is still hand-declared and must be **globally
unique** (`flake.modules.<class>` is one flat namespace) — it's the join key the
resolver selects on (e.g. `modules/dev/postgres.nix` is named `postgres-cli` so it
doesn't collide with `modules/homelab/postgres.nix`'s `postgres`).

The folder is authoritative — there is **no override hatch**. `wrapAspect` merges
the folder tag last (`recursiveUpdate m folderTags`), so a hand-written
`flake.aspectTags` in a leaf is inert; membership changes by **moving the file**.

[`import-tree`](https://github.com/vic/import-tree) (at the flake level in
`flake.nix`) auto-collects every such file — no hand-maintained `imports = [ … ]`.
The host builder (`hosts/default.nix`) then imports **only the leaves a host's
aspects select** (membership), routing nixos halves into the system and
homeManager halves into that user's home-manager. There is **no `mkIf <toggle>`
gate** in a leaf — being selected is the gate.

Conventions:

- **`_`-prefixed paths are skipped** by import-tree and by the host collector
  (helper files, page fragments): `modules/homelab/glance/_home-page.nix`,
  `modules/homelab/glance/_work-page.nix`.
- **Per-host files** live in the host's directory (`hosts/<h>/`) and are imported
  only for that host. Each is a **card** — same shape as `host.nix` — with its
  NixOS config in a `nixos` bucket (see "Aspects & host cards").
- The resolver is `lib/aspects.nix`; the bundle graph is in `aspects.nix`;
  shared cross-class options in `modules/fireproof-options.nix`.

### Aspects & host cards (`fireproof.*`)

A host selects **aspects** (membership tags), not toggles, via a
`hosts/<host>/host.nix` **card**: `{ aspects = [ … ]; shared = { fireproof.* … };
homeManager = { … }; }`. `shared` is a module merged into BOTH the nixos and the
home-manager evals (the no-bridge fact flow — no osConfig); `homeManager` is the
host's HM tweaks. The fleet is **discovered** — any `hosts/<name>/` directory
containing a `host.nix` is a host (`hosts/default.nix`); there is no central
registry. Inspect a host's resolution with **`just aspects <host>`**.

**Every** `.nix` file in a host dir is a card of that same shape `{ aspects?;
shared?; nixos?; homeManager?; }` — not just `host.nix`. The collector
(`hosts/default.nix`) asserts it: a bare NixOS module (a function, or an attrset
with any other top-level key) throws, pointing you at the `nixos` bucket. That
`nixos` bucket is the per-host analog of a dendritic leaf's
`flake.modules.nixos.<name>`. Buckets are merged across all cards in the dir, so
config/aspects/HM can live in `host.nix` or any sibling — e.g. `system.nix`
(nixos-only settings), `monitors.nix` (`shared.fireproof.monitors`), or an
aspect co-located with its config (minilab's `snapcast.nix` carries both
`aspects = ["snapcast"]` and the capture config).

An aspect carries **no data** — it is a pure membership tag. A "fact" is just a
`fireproof.*` option value set in a `shared` card or an aspect-tagged setter leaf
(e.g. `modules/desktop/enable.nix` sets `fireproof.desktop.enable` for the desktop
aspect); the module system merges those with real precedence.

Bundles in `aspects.nix` (`flake.bundles`) are **pure adjacency** (`name -> [the
bundles it pulls in]`). Only **composing** nodes appear there (`base`, `laptop`,
`gui-dev`, `gui-work`, `workstation`); every other aspect — including `desktop`
(now a leaf aspect: niri + dms + apps, the whole graphical session) — is a
pass-through name the closure carries via `or []`, so a leaf-only aspect needs **no
bundle entry**. `base` is prepended to every host and pulls in the always-on aspect
folders (`nix system cli secrets scripts fireproof-options docker`), so a leaf is
always-on by living in one of those folders.

Shared, cross-class options (`fireproof.{hostname,username,theme,monitors,
hardware.*,desktop.*,…}`) are declared once in `modules/fireproof-options.nix`
(emitted to both module classes).

### Home Manager

Author a feature's home-manager half as `flake.modules.homeManager.<name>`,
reading `config.fireproof.*` locally (facts are injected). It evaluates both
embedded (per host) and standalone (`lib/mkHome.nix` /
`homeConfigurations.portability-check`, with `osConfig = null`). The host builder
(`hosts/default.nix`) defines `home-manager.users.<user>` (the user read from
`config.fireproof.username`) and routes the selected homeManager leaves — plus the
host card's `shared` and `homeManager` buckets — into its `sharedModules`. There is
no `fireproof.home-manager` alias.

### Theme System

Colors in `modules/fireproof-options.nix` as `config.fireproof.theme.colors.*`:

```nix
let c = config.fireproof.theme.colors;
in {
  background = c.bg;        # Without # prefix
  border = "#${c.accent}";  # Add # when needed
}
```

### Membership, not mkIf

A leaf applies when its aspect is selected — do **not** wrap it in
`lib.mkIf <toggle>`. Put it in the right aspect folder instead:

```nix
# modules/desktop/foo.nix → selected when the host's closure has "desktop"
{
  flake.modules.nixos.foo = {pkgs, ...}: {
    environment.systemPackages = [pkgs.foo];
  };
}
```

To change a leaf's aspect, **move the file** to the right folder — the folder is the
sole source of membership; there is no `aspectTags` override.

Intra-module conditionals on `fireproof.*` option values (e.g.
`lib.optional config.fireproof.hardware.battery …`) are fine — those are
parameters, not membership.

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

- **New program / feature (leaf)**: Create the file **in the aspect folder that
  is its membership** — `modules/<aspect>/<name>.nix`, or `modules/<name>.nix` for
  a single-leaf aspect. Declare `flake.modules.nixos.<name>` and/or
  `flake.modules.homeManager.<name>` (no `mkIf` — membership gates it); **no
  `aspectTags` line** unless overriding the folder. Use an existing aspect folder,
  or add a new bundle in `aspects.nix` for a new one. For a homelab service also
  add a dashboard link in `modules/homelab/glance/_home-page.nix`.
- **New aspect/bundle**: Create the matching `modules/<name>/` folder; a leaf-only
  aspect needs **no `aspects.nix` entry** (it's a pass-through, resolved via `or
[]`). Add a `flake.bundles.<name> = [ … ]` entry in `aspects.nix` only if the
  aspect **composes** other bundles (edges). Always-on? add it to `base`'s edge
  list. Hosts select it by listing it in their `host.nix` card's `aspects`.
- **New host**: Run `just new-host <hostname> <username>` — it drops a
  `hosts/<hostname>/host.nix` card; edit its `aspects` (and `shared`/`homeManager`)
  to taste. The host is **discovered automatically** (the `host.nix` is the marker);
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

```bash
just secret-edit <name>  # Edit encrypted secret
just secret-rekey        # Rekey after adding hosts/secrets (touch YubiKey)
```

Two rekey stores per host, because `agenix rekey` deletes any file in a node's
`localStorageDir` that the node doesn't own — so the nixos and home-manager nodes
of one host **must not share a dir**:

- **`secrets/hosts/<h>/.rekey/`** — nixos secrets (`modules/secrets/secrets.nix`):
  `age.secrets.*` declared in a `flake.modules.nixos.*` half, decrypted by root.
- **`secrets/hosts/<h>/.rekey-hm/`** — home-manager secrets
  (`modules/secrets/hm-secrets.nix`): `age.secrets.*` declared in a
  `flake.modules.homeManager.*` half, decrypted during HM activation (as the user)
  via `~/.ssh/id_ed25519`. The `ssh-key` secret stays nixos-side because it _is_
  that identity (it can't decrypt itself). Both stores use the same `hostPubkey`,
  so the encrypted blobs are interchangeable.

## Maintaining This File

Update CLAUDE.md when making changes relevant to AI agents, such as:

- New just commands or workflows
- Changes to the module structure or `fireproof.*` options
- New patterns or conventions
