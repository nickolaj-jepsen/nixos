# Aspect structure (future direction)

Status: **future, deferred.** This builds on
[`options-migration-plan.md`](./options-migration-plan.md) — the `flake.modules` +
`feature` helper + bridge work is a prerequisite. Aspects are the _selection_ layer that
sits on top of it and eventually replaces the `fireproof.*.enable` toggles. Nothing here is
started; it's the agreed shape so the migration doesn't paint us into a corner.

## What an aspect is

Two kinds:

- **Leaf** — one `feature "<name>" {…}` call, i.e. one
  `flake.modules.{nixos,homeManager}.<name>`. About 80 of them, auto-imported. There is no
  `mkIf enable` inside a leaf: **membership in a selected bundle is the gate.**
- **Bundle** — an `includes`-only aspect, defined centrally. About ten of them. A bundle
  names the leaves and other bundles it pulls in.

The leaves already exist after the options migration (every feature file becomes a named
module). The aspect layer adds the bundle graph, a resolver, and per-host selection — and
deletes the enable-toggles.

## Decisions

| #   | Decision                                                                                                           | Rationale                                                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Fine-grained: one aspect per module (~80 leaves); bundles are `includes`-only.                                     | Leaves map 1:1 onto the `flake.modules` names already produced by the migration.                                                       |
| 2   | Intersections (`desktop ∩ dev`, `desktop ∩ work`) become their own bundles; hosts select the most-specific bundle. | A strict tree can't put `vscode` under two parents. An intersection bundle that `includes` both parents can.                           |
| 3   | Bundle membership is expressed as **central include-lists**, not reverse tags.                                     | Readability — a bundle's full contents are visible in one place. Accepts a hand-maintained list, mitigated by an orphan check (below). |
| 4   | Hardware capabilities stay **parameters**, not aspects.                                                            | dms reads `battery`/`wifi`/`gpuPciId` _inside_ a module to shape config — an intra-module conditional, not a whole-module gate.        |
| 5   | Opt-out defaults flip to opt-in.                                                                                   | `includes` can't subtract; the only real opt-out (minilab dropping chromium) is better expressed as "minilab never adds chromium."     |

## The bundle graph

This is the only hand-maintained part. Leaf names are the `flake.modules` names from the
migration.

```nix
# aspects.nix
windowManager.includes = [ niri-settings niri-binds niri-outputs
                           dynamic-workspaces dms ];

desktop.includes = [ ghostty gtk qt fonts firefox audio clipboard
                     default-apps recording keyd spotify obsidian
                     windowManager ];                 # niri → desktop, through the WM bundle

dev.includes  = [ python javascript k8s nats tilt mcp agents fnug
                  postgres emdash ];
work.includes = [ ssh-work ];                         # headless

gui-dev.includes  = [ desktop dev  vscode zed sublime ];   # the desktop ∩ dev editors
gui-work.includes = [ desktop work slack ferdium ];        # the desktop ∩ work apps
workstation.includes = [ gui-dev gui-work ];               # the full desktop/laptop/work box
intellij.includes    = [ gui-dev pycharm ];                # the one triple-intersection

physical.includes = [ btrfs-scrub smartd thermald journald zram ];
laptop.includes   = [ physical battery-svc wifi-svc backlight-svc ];
```

Bundles may also set parameter values, not just include leaves — see hardware below.

## Host selection

Each host names the bundles it wants; the resolver pulls the rest in transitively. Parametric
options (`hostname`, `gpuPciId`, snapcast captures, …) are set alongside, exactly as today.

```nix
desktop:  aspects = [ workstation physical nvidia ];   # + gpuPciId, snapcast, bambu, chromium, claude-work
laptop:   aspects = [ workstation laptop ];
work:     aspects = [ workstation physical nvidia ];   # + claude-work
minilab:  aspects = [ desktop physical ];              # + snapcast; no dev/work/chromium
homelab:  aspects = [ dev homelab physical ];          # headless
wsl:      aspects = [ dev work wsl ];                  # headless, no physical
```

## Resolver

At the flake-parts level: take the transitive `includes` closure of a host's `aspects`,
collect the leaf names, and splat the matching modules into each class.

```nix
# leafNames = transitive closure of aspects, keeping only names that are flake.modules leaves
nixosSystem.modules        += attrValues (getAttrs leafNames self.modules.nixos);
home-manager.sharedModules  = attrValues (getAttrs leafNames self.modules.homeManager);
# a future standalone homeConfigurations.<h> uses the same homeManager set, no bridge.
```

This is the resolution flake-aspects provides; hand-rolling the closure is ~15 lines.

**Orphan check.** Because membership is now a central list, a leaf that no bundle references
is silently dead. Add an eval assertion: every `attrNames self.modules.nixos` either appears
in some bundle's transitive closure or is explicitly marked standalone. Forgetting to wire a
new feature then fails loudly.

## Three judgment calls worth re-examining when this is built

1. **Hardware capabilities are parameters, not aspects.** This is the one place membership
   does _not_ replace toggles. `dms/bar.nix` and `control-center.nix` branch on
   `hardware.battery`/`wifi`/`dimmableBacklight`/`gpuPciId` _inside_ the module. So the
   `laptop` bundle does two jobs: it `includes` the battery/wifi/backlight service leaves
   **and** sets the facts (`hardware.battery = true`, …) that dms reads. Capabilities are
   options set by bundles; whole-module features are leaves.

2. **Opt-out defaults flip to opt-in.** `chromium`/`google-chrome`/`bambu`/`snapcast` leave
   bare `desktop` and become host-added (or members of a richer bundle). minilab selects
   plain `desktop` and simply never adds chromium — no negation mechanism needed.

3. **`pycharm` is the lone triple-intersection** (`desktop ∩ dev ∩ intellij`). Handle it with
   a single `intellij` bundle (`includes = [ gui-dev pycharm ]`) that hosts select instead of
   `gui-dev`. Don't build general N-way intersection machinery for one leaf.

## Relationship to the migration plan

Aspects sit strictly above the `flake.modules` layer:

- The migration plan (flake.modules, `feature` helper, shared options, bridge) is unchanged
  and is the prerequisite.
- Aspects add `aspects.nix`, the resolver, and the host `aspects = [ … ]` selection.
- The `fireproof.*.enable` toggles are deleted; membership replaces them.
- Parametric options (theme, hardware facts, snapcast captures, gpuPciId) are untouched —
  they were never the toggles.

## Not decided

- Whether to adopt flake-aspects as a dependency or hand-roll the resolver. flake-aspects
  gives `includes`/`provides` and the closure; hand-rolling is small and dependency-free. Pick
  when building.
- Whether bundles live in one `aspects.nix` or a few grouped files. Taste.
