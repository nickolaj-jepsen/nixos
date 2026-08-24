# Authoring module leaves

Read this before creating or restructuring anything under `modules/`.

## Dendritic leaves

Every `.nix` file under `modules/` is a flake-parts module declaring
`flake.modules.{nixos,homeManager,darwin}.<name>` — not a bare NixOS module.
[import-tree](https://github.com/vic/import-tree) auto-collects them all
(no `imports` lists to edit); `_`-prefixed paths are skipped (helper/fragment
files). The host builder imports **every** leaf into **every** host, so each
leaf must self-gate:

```nix
# modules/desktop/foo.nix — active only where fireproof.desktop.enable is true
{
  flake.modules.nixos.foo = {config, lib, pkgs, ...}: {
    config = lib.mkIf config.fireproof.desktop.enable {
      environment.systemPackages = [pkgs.foo];
    };
  };
  flake.modules.homeManager.foo = {config, lib, ...}: {
    config = lib.mkIf config.fireproof.desktop.enable { … };  # gate BOTH halves
  };
}
```

Rules:

- `lib.mkIf` gates `config` ONLY — `options` and `imports` stay at the top
  level. A leaf that `imports` a third-party module imports it on every host;
  that module must be inert when the feature is off.
- The module name is one flat global namespace; a duplicate silently
  deep-merges. E.g. `modules/programs/postgres.nix` is named `postgres-cli` to
  avoid colliding with `modules/homelab/postgres.nix`'s `postgres`.
- Folders are organization only — the gate is whatever option the `mkIf`
  reads. Convention: `desktop/*` gate `desktop.enable` (or a child),
  `homelab/*` gate `homelab.enable`, `programs/*` gate the relevant capability.
  Always-on leaves (`base/*`, `scripts/*`, baseline `programs/*` and
  `system/*`) are ungated.
- Conditionals on other `fireproof.*` values nest fine inside the gate
  (e.g. `lib.optional config.fireproof.hardware.battery …`).
- `nix` flake eval ignores git-untracked files — `git add` new files or they
  are invisible to builds.

## Options: nested + cascading

All `fireproof.*` options are declared centrally in
`modules/base/fireproof.nix` (theme in `modules/base/theme.nix`), emitted to
all module classes. Children default to their parent
(`desktop.chromium.enable` → `desktop.enable`; `hardware.physical` →
`!wsl.enable`; …), so hosts set parent toggles and override exceptions — this
cascade IS the composition layer. Opt-in extras (`hardware.nvidia`,
`dev.llm`, `desktop.{bambu-studio,google-chrome,snapcast,oxcbMedia,lan-mouse}`)
default off. Full reference: `docs/fireproof-options.md` (`just docs`).

New toggle: add `fireproof.<feature>.enable = lib.mkEnableOption "…";` (or a
cascading `lib.mkOption { default = config.fireproof.<parent>.enable; }`) to
`modules/base/fireproof.nix`; hosts enable it via
`shared.fireproof.<feature>.enable = true`.

There are no per-app GUI toggles — GUI apps gate on `desktop.enable` (plus
`dev`/`work` where relevant). Cross-platform packaging rules: `docs/hosts.md`.

## Home-manager halves

An HM half evaluates both embedded (NixOS hosts) and standalone
(`class = "home"`, where `osConfig = null`) — read `config.fireproof.*`, never
`osConfig`. `just check` builds `homeConfigurations.dev-ao` as the
standalone guard, so an osConfig read fails CI.

## Snippets

- Theme: `let c = config.fireproof.theme.colors; in { background = c.bg; border = "#${c.accent}"; }`
  (values have no `#` prefix).
- Unstable packages: `pkgs.unstable.<pkg>` (overlay on the pkgs set).
- `fpLib` (via specialArgs): `mkVirtualHost { port; websockets?; http2?; host?; }`,
  `mkPostgresDB { name; login?; authentication?; }`,
  `mkDarwinGuiPackage pkgs linuxPkg` — see `lib/default.nix`.

## Adding other things

- **Script**: `modules/scripts/`, `pkgs.writeShellApplication`, include
  `set -euo pipefail`.
- **Overlay**: `overlays/<name>.nix` (auto-imported). Add update instructions
  in `.github/workflows/update-overlays.md` (a gh-aw file), then
  `gh aw compile update-overlays`.
- **Agent skill**: skills for the coding agents flow through the
  `fireproof.agents.skills` registry (`attrsOf path`, merged across leaves).
  Own skills: repo-root `skills/<name>/SKILL.md` (auto-registered by
  `modules/programs/agent-skills.nix`; publicly installable, see
  `skills/README.md`). Third-party skills: registered by their feature leaf
  from the upstream source, e.g. `modules/programs/git.nix` registers
  `fireproof.agents.skills.gh-stack = "${pkgs.unstable.gh-stack.src}/skills/gh-stack"`.
