# Unified migration: dendritic `flake.modules` + aspects (no bridge)

Status: **planned, agreed shape.** This consolidates and **supersedes**
[`options-migration-plan.md`](./options-migration-plan.md) and
[`aspects-design.md`](./aspects-design.md) into a single migration, and **discards the
old `hm-refactor` branch** (older `flake.{nixos,home}Modules` schema + hand-maintained
`propagatedFireproof` mirror + explicit import list — all rejected below). Solved
sub-problems from that branch (HM-side agenix-rekey wiring, the dummy-pubkey trick,
`mkHome`, the secret-file moves) are reused as *mechanism*, not architecture.

The end state: every feature is a dendritic `flake.modules.{nixos,homeManager}` entry,
selection is by **aspects** (membership replaces `*.enable` toggles), and **no
`osConfig` bridge exists** — the home-manager eval never reads the NixOS eval, so it is
identical embedded or standalone. This is the substrate a future standalone-HM or
nix-darwin host drops onto with no rework.

## Goals

1. **Standardization** — adopt the official flake-parts `flake.modules.<class>.<name>`
   namespace and the dendritic pattern; author with plain module-system idioms, no
   bespoke DSL.
2. **Reduce complexity / avoid homebrew** — delete the `fireproof.home-manager` alias,
   the `feature` helper, and every cross-eval bridge/mirror. The only hand-rolled piece
   is a ~20-line aspect resolver (justified over a pre-1.0 solo dependency).
3. **DX** — adding a module stays a *one-file* change; adding a host is *drop a
   directory*, no central list to edit.
4. **Future-proofing** — standalone home-manager and nix-darwin become a few-line
   `mkHome`/`mkDarwin` call. Nothing in an HM half reads `osConfig`, proven continuously
   by a portability check.

## Non-goals

- No real standalone or darwin host is **deployed** this migration (only the throwaway
  `portability-check`). The machinery to add one is built and proven.
- No behaviour change is *intended*. Every host's system closure must match pre-migration
  (verified by `just diff`); any latent quirk we surface (see Risks) is an explicit,
  separate keep-or-drop decision.

## Resolved decisions

| #   | Decision                                                                                                  | Why                                                                                                             |
| --- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1   | Fresh on `main`; ignore the `hm-refactor` branch architecture.                                            | Its schema + mirror are exactly what this plan improves on.                                                    |
| 2   | One migration ending with **aspects live and toggles deleted**.                                           | The user asked for both docs implemented together.                                                             |
| 3   | **No `osConfig` bridge.** Facts resolved at the flake layer, pushed into both class-buckets.              | Community-cautioned-against; `osConfig == null` standalone. Aspects make facts flake-level-known, so it's moot. |
| 4   | Official `flake.modules.{nixos,homeManager,darwin}.<name>` (flake-parts `modules` extra).                 | Standard, darwin-ready, `_class`-stamped. Not the hand-rolled `homeModules`.                                   |
| 5   | **Plain dendritic authoring**, no `feature` helper. Options colocated per-half; ambient facts central.    | Aspects delete most per-feature cross-class options, so the helper's job evaporates. Least homebrew.           |
| 6   | **Hand-rolled** transitive-closure resolver (~20 lines), data shaped like den's `includes`.               | `flake-aspects` dormant/solo, `den` pre-1.0; a 20-line closure isn't worth that dependency. Drop-in to den later. |
| 7   | **Reverse-tags on leaves + small central bundle graph.**                                                  | One-file module adds (matches today's self-gating DX); bundle hierarchy still legible in one place.            |
| 8   | Hardware capabilities stay **parameters** (facts); opt-out flips to **opt-in**.                           | dms branches on `hardware.battery` etc. inside the module; `includes` can't subtract.                          |
| 9   | **Portability-check + `mkHome`**, no real standalone host deployed.                                       | Proves the no-bridge design; defers physical/darwin provisioning.                                              |
| 10  | **Substrate incrementally, then one big cutover commit; no mirror ever.** Gate: per-host `just diff`.     | User chose clean end-history; nvd closure-diff makes a large commit trustworthy.                               |
| 11  | User-scoped secrets (ssh, k8s, mcp, spotify) → **HM-side agenix-rekey**.                                  | Makes HM halves `osConfig`-free *and* standalone truly drop-in for secrets.                                    |
| 12  | Hosts **auto-collected** via a `flake.hosts` option; no central `targets` list.                           | Drop-a-dir host adds; matches the module auto-import philosophy.                                               |

## End-state architecture

### Module namespace and authoring

`flake.nix` enables the flake-parts `modules` extra and moves `import-tree ./modules` up
to the flake level (out of `nixosSystem`):

```nix
flake-parts.lib.mkFlake { inherit inputs; } {
  imports = [
    inputs.flake-parts.flakeModules.modules   # provides flake.modules.<class>.<name>
                                               # (verify attr path at impl; else import extras/modules.nix)
    inputs.agenix-rekey.flakeModule
    ./formatter.nix ./devshell.nix ./docs.nix ./overlays
    ./lib                                      # fpLib, resolver, mkHome, flake.hosts builder
    (inputs.import-tree ./modules)             # every feature file, auto-wired
    (inputs.import-tree ./hosts)               # every host's selection module, auto-wired
  ];
}
```

A feature file writes only the class-buckets it needs and self-declares membership.
No helper, no alias:

```nix
# modules/programs/ghostty.nix  — pure-HM feature
{
  flake.aspectTags.ghostty = [ "desktop" ];          # reverse-tag: one-file membership
  flake.modules.homeManager.ghostty = { config, lib, pkgs, ... }: {
    programs.ghostty = { /* reads config.fireproof.theme.colors locally */ };
  };
}
```

```nix
# modules/desktop/snapcast.nix  — nixos-only feature, options stay colocated
{
  flake.aspectTags.snapcast = [ "snapcast" ];        # its own opt-in bundle
  flake.modules.nixos.snapcast = { config, lib, ... }: {
    options.fireproof.desktop.snapcast = { /* sinkName, captures … nixos-only */ };
    config = { /* services.snapserver / pipewire — NO mkIf; membership is the gate */ };
  };
}
```

```nix
# modules/programs/spotify.nix  — dual feature (both classes), each half colocated
{
  flake.aspectTags.spotify = [ "desktop" ];
  flake.modules.nixos.spotify       = { /* … */ };
  flake.modules.homeManager.spotify = { /* … */ };
}
```

- **nixos-only / HM-only options** live inline in their half — colocated.
- **Cross-class ambient facts** (`theme`, `hardware.*`, `username`, `hostname`,
  `monitors`, `secretsDir`) live in one `modules/base/fireproof-options.nix`, emitted to
  **both** classes (`flake.modules.nixos.fireproof-options` and
  `flake.modules.homeManager.fireproof-options` = the same options module). This is the
  *only* place an option is declared into both evals, and it's declaration-once.
- **No `mkIf <toggle>` inside a leaf.** Presence in the resolved leaf set is the gate.
  Intra-module conditionals on *facts* (e.g. `lib.optional config.fireproof.hardware.battery …`)
  remain — those are parameters, not membership.

### Facts flow to home-manager without a bridge

Every value an HM half needs is known at the flake layer (bundle facts + host parametric
values), so the resolver injects it into both classes from one source. Because facts only
ever touch paths declared in the shared `fireproof-options` (present in both evals), this
needs **no introspection** — unlike the rejected self-adjusting bridge:

```nix
# inside the host-builder, per host:
nixosSystem.modules        ++= [ { fireproof = facts; } ];   # facts : the shared-option subset
home-manager.sharedModules ++= [ { fireproof = facts; } ];   # same value, both evals
```

Theme is static defaults in `fireproof-options`, so it needs no per-host injection at
all. `monitors` becomes a shared option set per-host as a fact (it's consumed only
HM-side today, but lives in both for a uniform mental model). Secrets are HM-side
agenix-rekey, so HM computes its own paths — never reads NixOS `config.age`.

### Aspects: resolver, bundles, tags

```nix
# lib/aspects.nix  (~20 lines incl. cycle-safety)
{ lib }: rec {
  # transitive closure of selected aspect names over the includes-graph
  closure = bundles: selected:
    let step = seen: frontier:
      if frontier == [] then seen
      else let n = lib.head frontier; rest = lib.tail frontier; in
        if lib.elem n seen then step seen rest
        else step (seen ++ [ n ]) (rest ++ (bundles.${n}.includes or []));
    in step [] selected;

  # names of leaves selected by a host = leaves whose tags intersect the resolved bundles
  selectedLeaves = bundles: aspectTags: hostAspects:
    let sel = closure bundles hostAspects; in
    lib.filter (name: lib.any (t: lib.elem t sel) aspectTags.${name})
               (lib.attrNames aspectTags);

  # merged facts from the selected bundles (host parametric facts override)
  facts = bundles: hostAspects: hostFacts:
    lib.recursiveUpdate
      (lib.foldl' lib.recursiveUpdate {} (map (b: bundles.${b}.facts or {}) (closure bundles hostAspects)))
      hostFacts;
}
```

```nix
# modules/base/aspects.nix  — the only hand-maintained graph (~10 bundles)
{
  flake.bundles = {
    windowManager.includes = [ "niri" "dms" "dynamic-workspaces" ];
    desktop.includes       = [ "windowManager" ];          # leaves tag themselves into "desktop"
    dev.includes           = [];                            # CLI dev tools tag into "dev"
    work.includes          = [];

    gui-dev.includes  = [ "desktop" "dev" ];                # desktop ∩ dev (editors tag into "gui-dev")
    gui-work.includes = [ "desktop" "work" ];               # desktop ∩ work
    workstation.includes = [ "gui-dev" "gui-work" ];

    physical.includes = [];                                 # btrfs-scrub/smartd/thermald/zram tag in
    laptop = { includes = [ "physical" ]; facts = { hardware = { laptop = true; battery = true; wifi = true; dimmableBacklight = true; }; }; };
    nvidia = { includes = []; facts = { hardware.nvidia.enable = true; }; };
    homelab.includes = [];
    wsl     = { includes = []; facts = { wsl.enable = true; }; };
    snapcast.includes = [];                                 # opt-in
    chromium.includes = [];                                 # opt-in (was an opt-out default)
  };
}
```

**Orphan check** (assertion in the builder + surfaced in `just check`): every
`flake.aspectTags.<name>` names a real leaf in some class; every tag names a defined
bundle; every leaf carries ≥1 tag or is explicitly `standalone`. A new feature you forget
to tag fails loudly.

### Host declaration and wiring

Each host directory contributes a flake-parts module registering its selection; hardware
files stay nixos modules and are collected from the same directory:

```nix
# hosts/desktop/default.nix  — flake-parts module (selection only)
{
  flake.hosts.desktop = {
    system  = "x86_64-linux";
    aspects = [ "workstation" "physical" "nvidia" "snapcast" "chromium" ];
    facts   = { hardware.gpuPciId = "10de:2c05"; monitors = import ./monitors.nix; };
    extraModules = [ ./facter.nix ./extras.nix ];   # nixos-only host bits: steam, runelite, claude-work, disk
  };
}
```

```nix
# hosts/default.nix  — one builder maps flake.hosts → nixosConfigurations
{ config, inputs, withSystem, ... }: {
  config.flake.nixosConfigurations =
    lib.mapAttrs (name: host: withSystem host.system ({ system, ... }:
      inputs.nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; fpLib = config.flake.lib.fpLib; };
        modules =
          baseSystemModules                                                    # disko, hm, agenix, niri, …
          ++ nixosLeavesFor name                                              # resolved via lib/aspects
          ++ [ { fireproof = factsFor name; } ]
          ++ [ (hmWiring name) ]                                              # home-manager.sharedModules = homeLeavesFor name ++ [{fireproof=facts;}]
          ++ host.extraModules;
      })) config.flake.hosts
    // bootstrapVariants;   # bootstrap + bootstrap-<name>, generated as today
}
```

Adding a host = drop `hosts/<h>/default.nix` (+ its hardware files). No central edit.

### Home-manager wiring (embedded + standalone)

- **Embedded:** `home-manager.sharedModules = homeLeavesFor host ++ [{ fireproof = facts; }]`
  plus `inputs.agenix.homeManagerModules.default` +
  `inputs.agenix-rekey.homeManagerModules.default`. `useGlobalPkgs`/`useUserPackages` as today.
- **Standalone:** `lib/mkHome.nix` calls `home-manager.lib.homeManagerConfiguration` with
  the **same** `homeLeavesFor`/facts, the HM agenix modules, niri's HM module (not
  auto-shared off-NixOS), and sets `home.username`/`homeDirectory`/`stateVersion` +
  `fireproof.*` directly. The pkgs/overlay set is factored out of `nixosSystem` and shared
  with `mkHome` (DRY).
- **Portability-check:** `flake.homeConfigurations.portability-check = mkHome { username =
  "check"; aspects = [ /* exercise the halves */ ]; }` with the dummy host-pubkey so
  agenix-rekey evaluates. Built by `just check`. This is the only thing that proves no HM
  half secretly reads `osConfig`.

### Secrets

The four HM-read secrets move to HM-side agenix-rekey (mechanism lifted from the old
branch): HM imports `agenix` + `agenix-rekey` homeManagerModules; `config.age.secrets.*`
resolves *within* HM (osConfig-free). One-time `just secret-rekey` (YubiKey) at cutover;
the dummy all-zero host-pubkey lets the portability-check eval produce placeholder
secrets. System-scoped secrets stay NixOS-side untouched.

## Bundle graph vs. the real host matrix

Derived from the actual host configs (not the doc sketch). Effective selections:

| Host        | Aspects                                          | Facts / host extras                                              |
| ----------- | ------------------------------------------------ | --------------------------------------------------------------- |
| desktop     | `workstation physical nvidia snapcast chromium`  | gpuPciId, monitors; steam, runelite, bambu-studio, claude-work  |
| laptop      | `workstation laptop chromium`                    | monitors                                                        |
| work        | `workstation physical nvidia chromium`           | monitors, claude-work; binfmt aarch64, firefox homepage         |
| homelab     | `dev homelab physical`                           | headless                                                        |
| minilab     | `desktop dev physical snapcast oxcb-media`        | snapcast turntable capture, monitors; **no** chromium, **no** gui-dev |
| desktop-wsl | `dev work wsl`                                    | usbip autoAttach; stateVersion 25.11                            |

This corrects the original aspects-design sketch, which dropped `dev` from minilab and
omitted per-host opt-ins (chromium/snapcast).

**Leaf placement is the execution-time work**, validated by nvd-diff. Key calls:

- `dev` bundle = headless CLI tools (python, javascript, k8s, nats, tilt, mcp, agents,
  fnug, postgres, emdash). The GUI editors (vscode, zed, sublime) tag `gui-dev`. pycharm
  tags `gui-dev` too (every dev+desktop host has it today via `dev.enable` default — the
  doc's "lone triple-intersection / separate `intellij` bundle" was wrong).
- `clickhouse`, `playwright`, `intellij` default-on under today's `dev.enable`, but
  **minilab turns them off**. So they cannot live in plain `dev`. Place them in `gui-dev`
  (or a `dev-extras` sub-bundle that `gui-dev` includes) so minilab's `[desktop dev]` omits
  them while the workstation hosts get them.

## Migration phases

Substrate lands incrementally and keeps every host building identically. Then a single
cutover commit flips selection and deletes the legacy path.

- **P0 — prep.** Move `import-tree` to flake level; wrap each existing module as
  `flake.modules.nixos.<name>` (still `mkIf`-gated, imported wholesale; HM still via the
  alias). Enable the flake-parts `modules` extra. Build identical. `just diff` empty.
- **P1 — inert substrate.** Add `fireproof-options` (both classes), `lib/aspects.nix`,
  `flake.bundles`/`flake.aspectTags` options, `flake.hosts` + the host-builder skeleton,
  `mkHome`, the portability-check, the fact-flow plumbing, the orphan check. All inert:
  no leaf is tagged yet, hosts still drive via toggles, alias still wires HM. Build
  identical. `just diff` empty.
- **P2 — the cutover (one commit).** For every feature at once: split the HM config out of
  the alias into `flake.modules.homeManager.<name>`, add `flake.aspectTags`, drop
  `mkIf <toggle>` from the nixos halves, move the four secrets to HM agenix-rekey
  (`just secret-rekey`), flip each `hosts/<h>` to `flake.hosts.<h> = { aspects; facts; }`,
  switch HM wiring to resolver-splatted `sharedModules`, and delete the
  `fireproof.home-manager` alias, the `*.enable` toggle declarations, and the wholesale
  nixos import. **Gate:** `just build-system <h>` + `just diff <h>` per host must be empty
  (modulo intended changes); portability-check builds; orphan check passes.
- **P3 — cleanup + docs.** Repoint `docs.nix` at the nixos eval superset (optionally also
  render HM-only options from the portability-check eval). Add `just aspects <host>`
  (prints resolved bundles + leaves). Update `AGENTS.md` (new authoring/host/aspect
  conventions). Delete the two superseded docs.

## Verification

- **`just diff <host>`** (nvd closure diff, old-vs-new) per host — the primary
  behaviour-preservation gate for the cutover.
- **`just check`** runs the orphan check and builds `homeConfigurations.portability-check`
  (osConfig=null) — proves the HM halves are extractable.
- **`just build-system <host>`** for each host after P0, P1, and the cutover.

## nix-darwin readiness (future, not this migration)

The design leaves darwin a drop-in: a feature that applies to macOS adds
`flake.modules.darwin.<name>` and tags as usual; a darwin host registers `flake.hosts.<h>`
with `system = "aarch64-darwin"` and the builder grows a `darwinSystem` arm; HM on darwin
reuses the same `homeLeavesFor` via `home-manager.darwinModules`. Because no HM half reads
`osConfig` and facts flow from the flake layer, **nothing in the leaf set changes**. Keep
HM halves platform-clean (guard Linux-only bits with `lib.optionals pkgs.stdenv.isLinux`)
— the portability-check on a linux builder won't catch darwin-only assumptions, so this
stays a convention until a real darwin host exists.

## Risks / open execution items

- **Leaf placement & latent quirks.** The bundle→leaf mapping is the bulk of the cutover.
  `dev.enable` today latently installs IntelliJ/clickhouse/playwright on **headless
  homelab**; reproducing exactly keeps them, but this is worth an explicit keep-or-drop
  call (nvd-diff will make it visible). Same for any other default-on surprise.
- **One large cutover commit.** Mitigated by the nvd-diff gate, but review is hard;
  consider building the cutover on a scratch worktree and diffing closures for all six
  hosts before committing.
- **`flake.modules` extra attr path** — verify `inputs.flake-parts.flakeModules.modules`
  vs importing `extras/modules.nix` directly.
- **YubiKey ceremony** at cutover (`just secret-rekey`) is physical and must be sequenced
  with whoever holds the key.
- **`docs.nix`** sees only the nixos-eval options (shared + nixos-only). HM-only options
  (rare) need the second render or they're undocumented.

## Standardization notes

What's official vs. ours: the namespace (`flake.modules.*`), import-tree, agenix-rekey,
flake-parts, the HM flake module — all upstream. The only hand-rolled code is the ~20-line
resolver and the bundle/tag options. The bundle data is deliberately shaped like
[`den`](https://github.com/denful/den)'s `includes` model, so if den stabilizes past 1.0
the resolver is a drop-in replacement rather than a rewrite.
