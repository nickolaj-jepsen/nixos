# Agent notes

"Update the X config" usually means the config in this repo — e.g. claude-code
lives in `modules/programs/claude-code`, vscode in `modules/programs/vscode`.

## Commands

All operations use `just`; run `just` for the full list.

```bash
just eval <attr> [host]  # One config value in seconds; hm.<attr> for home-manager. Try before build
just build [host]        # Verify builds with this, not switch
just try <app>           # One app with the new home-manager config, sandboxed; no switch, Linux only
just switch [host]       # NEEDS EXPLICIT USER APPROVAL, same for `just boot`
just fmt                 # ALWAYS run before finishing
just check               # Full flake check (slow, use sparingly)
just secret-edit <path>  # PATH to the .age file, not a bare name
just secret-rekey        # Needs the user's YubiKey
```

## Architecture in brief

A NixOS flake managing NixOS, standalone home-manager and nix-darwin hosts.
Every `.nix` file under `modules/` is a dendritic flake-parts leaf
(`flake.modules.{nixos,homeManager,darwin}.<name>`), auto-imported into
**every** host — so each leaf must gate its `config` with `lib.mkIf
config.fireproof.<feature>.enable` (both halves; `options`/`imports` stay
outside the mkIf). `fireproof.*` options are declared centrally in
`modules/base/fireproof.nix`, nest, and cascade (child enables default to their
parent). A host is a `hosts/<name>/` dir of cards setting toggles via
`shared.fireproof.<feature>.enable = true`; discovery is automatic. New files
must be `git add`ed or flake eval ignores them.

## Other entry points

- `nickolaj-jepsen/agents` (checked out at `fireproof.agents.devCheckout`) has
  the skills, plugins and UI kits, with its own AGENTS.md and README.md.
- `pkgs/agent-hub/README.md` describes the hub's states and links.

## Comments

Put a trap at the line that causes it. Add it here only if every task needs
it. Don't create docs pages. CLAUDE.md just `@`-includes this file.
