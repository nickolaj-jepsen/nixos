# Options migration plan: shared `fireproof` options across NixOS + home-manager

Status: **planned, not started.** This is the agreed direction for restructuring how
`fireproof.*` options and feature modules are organised, so that each feature's
home-manager half becomes separately evaluable (a precondition for home-manager-only
hosts later) and the `fireproof.home-manager` alias goes away.

## Goal and non-goals

**Goal.** Author every feature as a flake-parts `flake.modules.{nixos,homeManager}.<name>`
entry, with cross-class options declared in both module systems and a bridge feeding
values across in the embedded case. The home-manager half of a feature must evaluate
without the NixOS `config` present.

**Non-goals (deliberately deferred):**

- No standalone `homeConfigurations.<name>` are deployed. There is no non-NixOS machine
  yet; this is future-proofing.
- The 9 `fireproof.*.enable` toggles stay. Aspect-style _selection_ (the den /
  flake-aspects "a host lists its aspects" model) is a separate, later project. The
  structure below is its substrate, so adopting it later is additive rather than a rewrite.

## The three module systems

Keeping these straight is the whole point of the design:

1. **flake-parts** — evaluated once, produces flake outputs (`nixosConfigurations`,
   `nixosModules`, `flake.modules.*`, a future `homeConfigurations`). This is the
   _composition_ layer: which modules exist and which configuration each flows into.
   `hosts/default.nix` and `overlays/default.nix` already live here.
2. **NixOS module system** — evaluated per host inside `nixosSystem`. Home of
   `config.services.*`, the toggles, `snapcast.sinkName`.
3. **home-manager module system** — evaluated per user; `config.programs.*`, and after
   this work its own `config.fireproof.*`.

flake-parts answers _where feature modules live and how they're routed_. It does **not**
host `fireproof.*` options or the bridge — those are irreducibly inner-layer concepts.

## Decisions

| #   | Decision                                                                                                            | Rationale                                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| 1   | HM-only is future-proofing only; no standalone outputs deployed.                                                    | No non-NixOS machine exists.                                                |
| 2   | Keep the 9 enable-toggles; defer aspect-selection.                                                                  | Composition isn't the pain point.                                           |
| 3   | Full portability now, migrated feature-by-feature.                                                                  | Make the HM half genuinely extractable.                                     |
| 4   | Cross-class data reaches HM via shared options + a bridge, not `extraSpecialArgs`.                                  | Keeps the options system; standalone-friendly.                              |
| 5   | Only the cross-class subset is shared; nixos-only options stay nixos-only.                                          | "Everything everywhere" forces splitting modules that can't evaluate in HM. |
| 6   | Composition lives at `flake.modules.{nixos,homeManager}.<name>`.                                                    | Correct layer; the flake-aspects substrate.                                 |
| 7   | Uniform: all of `modules/` become `flake.modules.nixos.<name>`; nixos-only ones omit the homeManager half.          | One rule.                                                                   |
| 8   | Author via a thin `feature` helper that declares `options` into both halves.                                        | Colocation; can't forget to declare a cross-class option in HM.             |
| 9   | Self-adjusting bridge: introspect HM's own `options.fireproof`, copy matching paths from `osConfig` as `mkDefault`. | Cannot drift as features migrate.                                           |
| 10  | Delete the `fireproof.home-manager` alias; splat `attrValues self.modules.homeManager` into the embedded HM eval.   | The alias was the indirection to remove.                                    |

### Why snapcast was never a problem

`snapcast.sinkName` (and the `captures` submodule) only configure `services.snapserver`
and `services.pipewire` — NixOS-only. snapcast appears in zero home-manager-authoring
files, so it is a nixos-only feature: its options live in its `nixos` half and never cross
the boundary. The original worry ("aspects are on/off, where do parametric options go?")
dissolves because options live _inside_ a feature's class-half, not at the selection layer.

## End-state shape

```nix
# flake.nix — import-tree for modules/ moves up to the flake-parts level,
# alongside the existing flake-parts modules.
imports = [
  inputs.agenix-rekey.flakeModule
  ./formatter.nix ./devshell.nix ./docs.nix ./hosts ./overlays
  (inputs.import-tree ./modules)        # was: import-tree inside each nixosSystem
];
# inject the helper so every feature file (now a flake-parts module) receives it:
_module.args.feature = import ./lib/feature.nix { inherit lib; };
```

```nix
# a feature file, e.g. modules/programs/intellij.nix
{ feature, lib, ... }:
feature "intellij" {
  options.fireproof.dev.intellij.enable = lib.mkEnableOption "IntelliJ IDEs";

  nixos = { config, pkgs, lib, ... }:
    lib.mkIf config.fireproof.dev.enable {
      environment.systemPackages = [ pkgs.jetbrains.idea ];
    };

  homeManager = { config, lib, ... }:
    lib.mkIf config.fireproof.dev.intellij.enable {
      home.file.".ideavimrc".text = "...";
    };
}
```

```nix
# a nixos-only feature keeps colocation, just omits the homeManager half:
{ feature, lib, ... }:
feature "snapcast" {
  options.fireproof.desktop.snapcast = { /* enable, sinkName, captures … */ };
  nixos = { config, lib, ... }: lib.mkIf config.fireproof.desktop.snapcast.enable { /* … */ };
}
```

### The `feature` helper

```nix
# lib/feature.nix
{ lib }:
name: spec:
let
  optionsModule = { options = spec.options or {}; };
  half = body: { imports = [ optionsModule body ]; };
in
{
  flake.modules.nixos.${name} = half (spec.nixos or {});
}
// lib.optionalAttrs (spec ? homeManager) {
  flake.modules.homeManager.${name} = half spec.homeManager;
}
```

The same `options` attr is imported into both emitted halves, so a cross-class option is
declared once per eval. A nixos-only feature omits `homeManager`, so its options never
enter the HM eval — exactly the cross-class-subset rule, enforced by construction. (Add an
assertion on `name` collision as a nicety; two files claiming the same name otherwise merge
silently.)

### Base shared options

The ambient cross-class declarations that aren't tied to one feature — the base toggles
(`desktop.enable`, `dev.enable`, `work.enable`), `theme`, the `hardware.*` facts, and
identity (`username`, `hostname`) — are a feature with only options (plus the theme
derivation on the nixos side):

```nix
feature "fireproof-base" {
  options.fireproof = { /* toggles, theme, hardware, identity … */ };
  nixos = { config, ... }: { /* theme.colors derivation, base defaults */ };
}
```

This is what makes `lib.mkIf config.fireproof.dev.enable` resolve inside a home-manager half.

### Host-builder and the bridge

```nix
# hosts/default.nix (sketch) — toggles still gate everything.
nixosSystem {
  specialArgs = { inherit inputs fpLib; };
  modules = (lib.attrValues self.modules.nixos) ++ hostDirModules ++ [{
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = { inherit inputs fpLib; };     # HM halves need these too
    home-manager.users.${username}.imports =
      (lib.attrValues self.modules.homeManager) ++ [ ./bridge.nix ];
  }];
}
```

```nix
# bridge.nix — embedded-only; lives in the host-builder, NOT in flake.modules.homeManager.
{ options, osConfig, lib, ... }:
{
  config.fireproof =
    lib.mkDefault (lib.getAttrs (builtins.attrNames options.fireproof) osConfig.fireproof);
}
```

Because the bridge copies exactly the option paths the HM eval declares, it can't set an
undeclared option (eval error) and won't miss a newly-added cross-class option (silent
default). A future standalone `homeConfigurations.<name>` simply omits `bridge.nix` and sets
`fireproof.*` directly — it has no `osConfig`.

## Migration sequence (strangler)

The old and new paths coexist until the last feature moves.

1. **Scaffold, no behaviour change.** Move `import-tree` for `modules/` up to the flake
   level, wrapping each existing file as `flake.modules.nixos.<name>`. The builder splats
   `attrValues self.modules.nixos`. Hosts build identically; the alias still works.
2. **Add `fireproof-base` and `bridge.nix`.** Both inert until something reads
   `config.fireproof` on the HM side.
3. **Migrate features one at a time.** For each: lift the HM config out of
   `fireproof.home-manager.*` into the feature's `homeManager` half (move any upstream HM
   `imports` — dms, niri-dynamic-workspaces — in with it), and delete that alias usage.
   Re-run the portability check (below) after each.
4. **Delete the alias.** When the last migrant is done, remove `modules/base/home-manager.nix`
   and the `fireproof.home-manager` option.

### Per-feature checklist

- [ ] File returns `feature "<name>" { … }` and takes `feature` as a module arg.
- [ ] Cross-class options moved into `options`; nixos-only options stay in the `nixos` half.
- [ ] HM config moved from `fireproof.home-manager.*` into `homeManager`, reading
      `config.fireproof.*` locally.
- [ ] Upstream home-manager `imports` moved into the `homeManager` half.
- [ ] Portability check still evaluates.

## Verification

Add a throwaway standalone configuration built purely from the home-manager halves, with a
dummy user, evaluated in `just check`:

```nix
flake.homeConfigurations.portability-check =
  inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = …;                                  # any supported system
    modules = (lib.attrValues self.modules.homeManager) ++ [{
      home.username = "check";
      home.homeDirectory = "/home/check";
      home.stateVersion = "24.11";
      fireproof = { /* minimal toggles to exercise the halves */ };
    }];
  };
```

This is the only thing that proves a home-manager half doesn't secretly depend on
`osConfig` or a non-bridged option. Without it, "portability now" is unverified until the
first real standalone host years later — and the copy-too-little failure mode is silent.

## Open tasks / risks

- **`docs.nix` / `just docs`** renders `fireproof.*` from a single eval; the options now
  exist in two. Point it at the nixos eval (the superset).
- **`feature` name uniqueness** — add the assertion noted above.
- **Cross-class reads of nixos-only options.** The helper only guarantees an option is in
  HM if its feature emits a `homeManager` half. If some HM half reads an option declared
  only by a nixos-only feature, it won't be in the HM eval — the portability check catches
  this. Today only `fireproof.*` is read HM-side and `snapcast`/`homelab`/`wsl` are not, so
  no current violation.
- **`hardware.nvidia.enable` is cross-class** (`nvidia.nix` writes HM config too) — an easy
  one to mis-file as nixos-only during migration.

## Explicitly out of scope

- Aspect-style selection (den / flake-aspects). Deferred; this layout is its substrate.
- Where the `feature` helper is namespaced (`fpLib` vs standalone) — taste; it must be
  injected at the flake-parts level either way.
