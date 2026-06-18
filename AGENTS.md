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

This is a NixOS flake-based configuration managing 7 hosts with a custom `fireproof.*` options namespace.

### Structure

```
hosts/                    # Per-host configs; default.nix = mkSystem + host aspects/facts
lib/                      # Shared helpers (fpLib) + the aspect resolver (aspects.nix)
aspects.nix               # Bundle DAG (includes) + facts — the aspect registry
modules/                  # ONE FOLDER PER ASPECT: the folder a file is in IS its membership
  ├── <name>.nix          #   a file directly under modules/ = a single-leaf aspect
  │                       #   (nvidia, wsl, docker, chromium, clickhouse, intellij, …)
  ├── nix/ system/ cli/   #   always-on aspects (pulled in by base.includes)
  │   secrets/ scripts/
  ├── desktop/ windowManager/ dev/ gui-dev/ gui-work/   # capability aspects
  ├── physical/ laptop/   #   hardware aspects
  └── homelab/            #   server services (arr, jellyfin, nginx, …)
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

**Override hatch:** an explicit `flake.aspectTags.<name> = [...]` in a file _wins_
over the folder default — for the rare leaf whose membership differs from where it
sits, or that wants multiple bundles. Two such cases exist: `desktop/dms/default`
tags `windowManager`, and `homelab/default` (`homelab-options`) tags `base`.

[`import-tree`](https://github.com/vic/import-tree) (at the flake level in
`flake.nix`) auto-collects every such file — no hand-maintained `imports = [ … ]`.
The host builder (`hosts/default.nix`) then imports **only the leaves a host's
aspects select** (membership), routing nixos halves into the system and
homeManager halves into that user's home-manager. There is **no `mkIf <toggle>`
gate** in a leaf — being selected is the gate.

Conventions:

- **`_`-prefixed paths are skipped** by import-tree (helper files, page
  fragments): `modules/homelab/glance/_home-page.nix`, `hosts/<h>/_monitors.nix`.
- **Per-host files** live in the host's directory (`hosts/<h>/`) and are imported
  only for that host (still plain NixOS modules).
- The resolver is `lib/aspects.nix`; the bundle graph + facts are in `aspects.nix`;
  shared cross-class options in `modules/fireproof-options.nix`.

### Aspects & options (`fireproof.*`)

A host selects **aspects** (bundles), not toggles. Bundles live in `aspects.nix`
(`flake.bundles`): each names other bundles it `includes` and the `fireproof.*`
**facts** it sets. A host lists its aspects + host-specific facts in
`hosts/default.nix` (`targets.<host> = { dir; aspects; facts; }`). The resolver
(`lib/aspects.nix`) turns aspects into (a) the selected-leaf set and (b) the fact
set, which the builder injects into BOTH the nixos and home-manager evals — no
osConfig bridge. Inspect a host's resolution with **`just aspects <host>`**.

`base` is prepended to every host and is a **composition node**: its `includes`
pull in the always-on aspect folders (`nix system cli secrets scripts
fireproof-options docker`). So a leaf is always-on by living in one of those
folders. A folder name used as a membership target should be declared as a bundle
in `flake.bundles` (an empty `includes = []` is fine) so the aspect registry stays
complete.

Shared, cross-class options (`fireproof.{hostname,username,theme,monitors,
hardware.*,desktop.*,dev.*,…}`) are declared once in
`modules/fireproof-options.nix` (emitted to both module classes).

### Home Manager

Author a feature's home-manager half as `flake.modules.homeManager.<name>`,
reading `config.fireproof.*` locally (facts are injected). It evaluates both
embedded (per host) and standalone (`lib/mkHome.nix` /
`homeConfigurations.portability-check`, with `osConfig = null`). The host builder
(`hosts/default.nix`) defines `home-manager.users.<user>` and routes the selected
homeManager leaves — plus any per-host `homeModules` (e.g. `hosts/<h>/_home.nix`) —
into its `sharedModules`. There is no `fireproof.home-manager` alias.

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

To place a leaf in a different/extra bundle than its folder implies, either move
the file, or add the override `flake.aspectTags.foo = ["windowManager"];`.

Intra-module conditionals on _facts_ (e.g.
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
- **New aspect/bundle**: Add it to `flake.bundles` in `aspects.nix` (its
  `includes` edges and any `facts` it sets); create the matching `modules/<name>/`
  folder; hosts select it in `hosts/default.nix`. (Always-on? add it to
  `base.includes`.)
- **New host**: Run `just new-host <hostname> <username>`, then add a
  `targets.<hostname> = { dir = ./<hostname>; aspects = [ … ]; facts = { … }; }`
  entry in `hosts/default.nix`. Per-host files (`disk-configuration.nix`,
  `_monitors.nix`, …) go in the host directory. To install on physical hardware,
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
