# Agent notes

"Update the X config" usually means the config in this repo — e.g. claude-code
lives in `modules/programs/claude-code`, vscode in `modules/programs/vscode`.

## Commands

All operations use `just`; run `just` for the full list.

```bash
just switch [host]       # Rebuild + switch (NEEDS EXPLICIT USER APPROVAL, same for `just boot`)
just test                # Apply temporarily (reverts on reboot)
just build-system        # Build without switching — use this to verify builds
just diff                # Preview changes vs current system
just fmt                 # Format all files (ALWAYS run before finishing)
just check               # Full flake check (slow, use sparingly)
just docs                # Regenerate docs/fireproof-options.md
just secret-edit <path>  # Edit a secret (PATH to the .age file, not a bare name)
just secret-rekey        # Rekey after adding hosts/secrets (YubiKey)
```

## Architecture in brief

A NixOS flake managing 8 hosts (6 NixOS, 1 standalone home-manager, 1
nix-darwin). Every `.nix` file under `modules/` is a dendritic flake-parts
leaf (`flake.modules.{nixos,homeManager,darwin}.<name>`), auto-imported into
**every** host — so each leaf must gate its `config` with
`lib.mkIf config.fireproof.<feature>.enable` (both halves; `options`/`imports`
stay outside the mkIf). `fireproof.*` options are declared centrally in
`modules/base/fireproof.nix`, nest, and cascade (child enables default to
their parent). A host is a `hosts/<name>/` dir of cards setting toggles via
`shared.fireproof.<feature>.enable = true`; discovery is automatic. New files
must be `git add`ed or flake eval ignores them.

## Read before touching

- `docs/modules.md` — creating/editing leaves under `modules/`: gating rules,
  option cascade, new toggles, theme/unstable/fpLib, overlays, scripts,
  agent skills.
- `docs/hosts.md` — anything under `hosts/`: card shape, classes
  (nixos/home/darwin), cross-platform app packaging, new-host/bootstrap.
- `docs/secrets.md` — anything under `secrets/`: rekey stores, secret-write
  vs secret-edit, YubiKey needs.
- `docs/homelab.md` — adding a homelab service: containers, shared
  postgres/mariadb, glance dashboard.
- `docs/fireproof-options.md` — generated reference of all `fireproof.*`
  options.

## Maintaining these files

When making changes relevant to AI agents (new commands, structure, patterns),
update the matching `docs/` page — or this file only for things every task
needs. CLAUDE.md just `@`-includes this file.
