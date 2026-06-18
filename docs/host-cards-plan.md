# Host cards + facts collapse — plan

Status: **planned, pure-Nix, no YubiKey.** The dendritic finish work is fully applied: no
`fireproof.home-manager` alias, the four secret leaves (ssh/k8s/mcp/spotify) are dendritic HM
agenix-rekey leaves in their aspect folders, `wrapAspect` is the folder-stamping branch only, the
central `aspectTags` block is gone, and all hosts have switched. This plan removes the two remaining
warts: the **`facts` data-merge layer** and the **central `targets` registry**. Each host folder ends
up describing its own aspects and config like every other dendritic module.

Every step is **config-preserving** and provable by **`system.build.toplevel.drvPath` equality** — a
pure relocation of facts produces identical realized config, so each host's toplevel derivation hash
must be byte-identical before vs after (strictly stronger than the package-set parity the migration
used; that stays the localizing fallback).

Order: **P-facts → P-cards → P-discovery.** Each phase is independently verifiable; commit after each.
The branch stays switchable throughout.

## Why

- A "fact" is just a `fireproof.*` option value. Those options are emitted to **both** module classes
  (`fireproof-options.nix`), so any module touching only `fireproof.*` is class-agnostic and importable
  into both evals — and the module system already merges option values with real precedence. The `facts`
  resolver (`lib/aspects.nix`: `recursiveUpdate`/`foldl'` + `{fireproof = resolvedFacts;}` injection) is a
  weaker parallel merge engine running beside the real one. Delete it.
- An **aspect** then carries no data — it is a pure membership tag. The bundle DAG collapses to a
  ~6-line adjacency list.
- A **host** stops being a central `targets.<h> = {dir; aspects; facts; homeModules;}` entry and becomes
  a `hosts/<h>/host.nix` card colocated with the rest of its folder; the fleet is discovered, not
  enumerated.

## Verification (the gates)

- **toplevel parity (primary):** `nix eval .#nixosConfigurations.<h>.config.system.build.toplevel.drvPath`
  for all 6 hosts — must be byte-identical before vs after. If any differs, drop to package-set parity to
  localize.
- **package-set parity (localizing):** sorted `environment.systemPackages` +
  `home-manager.users.<u>.home.packages` outPaths, before vs after.
- `nix build .#homeConfigurations.portability-check.activationPackage` — standalone HM still builds
  (drvPath parity too).
- `just aspects <h>` — resolved aspects / closure / leaves unchanged.
- Cadence: capture the pristine baseline **before any edit**; eval each phase for errors as it lands;
  run the full parity diff **once at the end**. No switch — activation is a closure no-op.

---

## P-facts — collapse facts into the module system

Parity-preserving because every option a bundle's `facts` used to set is either **relocated to a tiny
setter leaf** (the load-bearing flags) or **deleted** (vestigial flags with zero readers). Reader sets
below were re-grepped against the current tree (alias-aware: `cfg = config.fireproof.*` indirections
counted).

### 1. Make `flake.bundles` pure adjacency

In `aspects.nix`, change the option to `lib.types.lazyAttrsOf (lib.types.listOf lib.types.str)` and drop
the `facts` field. `config.flake.bundles` keeps only the nodes that _compose_ (including `base`); every
other aspect is a pass-through name the closure carries via `or []`:

```nix
config.flake.bundles = {
  base        = ["nix" "system" "cli" "secrets" "scripts" "fireproof-options" "docker"];
  desktop     = ["windowManager"];
  laptop      = ["physical"];
  gui-dev     = ["desktop" "dev"];
  gui-work    = ["desktop" "work"];
  workstation = ["gui-dev" "gui-work"];
};
```

> `base` MUST stay — the builder prepends it and the always-on folders ride in on its `includes`.
> Pass-through aspects (`nix`, `dev`, `work`, `nvidia`, `chromium`, …) need no entry: `closure` adds the
> name to the closure and `bundles.${n} or []` yields no further edges.

In `lib/aspects.nix`: `closure` reads `bundles.${n} or []` (was `bundles.${n}.includes or []`); **delete
the `facts` function**; keep `closure` + `selectedLeaves`.

### 2. Relocate the load-bearing capability flags

Four flags are read by _always-present_ modules (so membership alone can't carry them). Each becomes a
tiny dual-declared setter leaf, folder-tagged into its aspect. **The option declarations stay in
`fireproof-options.nix`; only the value moves from a bundle fact to the leaf.**

| flag                      | live reader(s) (always-present)                                                                  | setter leaf (new)                             |
| ------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| `desktop.enable`          | `scripts/default.nix` (in `cli`/base); also `greetd`, control-center                             | `modules/desktop/enable.nix`                  |
| `work.enable`             | `secrets/ssh.nix` (base)                                                                         | `modules/work/enable.nix` (new folder)        |
| `hardware.laptop`         | `battery`/`wifi`/`dimmableBacklight` option defaults                                             | `modules/laptop/enable.nix` (folder exists)   |
| `claude-code.work.enable` | `cli/claude-code/default.nix` (base) — gates `claudeWorkWrapper` pkg + `.claude-work/*` symlinks | `modules/claude-work/enable.nix` (new folder) |

Setter-leaf shape (dual-declared so both evals see it; folder stamps the aspect tag):

```nix
# modules/desktop/enable.nix  -> wrapAspect stamps aspectTags.desktop-enable = ["desktop"]
let m = {fireproof.desktop.enable = true;};
in {
  flake.modules.nixos.desktop-enable = m;
  flake.modules.homeManager.desktop-enable = m;
}
```

`claude-work` selects on `desktop`+`work` hosts today (desktop, work) — matches current behavior. Module
names must be globally unique: `desktop-enable`, `work-enable`, `laptop-enable`, `claude-work-enable`.

### 3. Delete the vestigial / dead flags

Zero live readers → removing the option (and its old bundle fact) changes nothing realized; the parity
gate catches a miss. Their aspects keep working as **pure tags** (the leaves are selected by membership,
never by the flag).

Plain vestigial (declared, never read):

`desktop.chromium.enable`, `desktop.bambu-studio.enable`, `desktop.google-chrome.enable`,
`desktop.windowManager.enable`, `dev.enable`, `dev.intellij.enable`, `dev.clickhouse.enable`,
`dev.playwright.enable`, `hardware.nvidia.enable`.
(The whole `dev` block disappears; `desktop` keeps only `enable`.)

`homelab.enable` — one reader, `homelab/immich.nix`'s `mkIf config.fireproof.homelab.enable (…)`. Since
immich lives in `homelab/` it is already membership-gated and the `mkIf` was always-true when imported.
**Delete the option AND strip the `mkIf` wrapper from immich.nix** (parity-preserving). The other ~17
homelab leaves alias `cfg = config.fireproof.homelab` but read only `cfg.domain`/`cfg.acmeEmail`, which
stay (declared in `homelab/default.nix`).

Dead derived chain — `wsl.enable → hardware.physical → hardware.zram` — has no live reader (the
`zram`/`btrfs-scrub`/`smartd`/`thermald` leaves are pure membership in `physical/`; `modules/wsl.nix` is
pure membership too). **Purge all three.** No `wsl` setter is needed.

After this, `fireproof-options.nix` keeps: `hostname`, `username`, `work.enable`, `desktop.enable`,
`claude-code.work.enable`, `hardware.{laptop,gpuPciId,battery,wifi,dimmableBacklight}`, `bootstrap.targetHost`,
`base.defaults.terminal`, `monitors`, `theme.*`.

### 4. Simplify the fact injection

In `mkSystem` (`hosts/default.nix`), `resolvedFacts = aspectsLib.facts …` becomes the host's own
`facts` directly; inject `{fireproof = host.facts;}` into both evals (no bundle merge). In `lib/mkHome.nix`,
`resolvedFacts = facts // {inherit username;}` directly. Both `aspectsLib.facts` call sites disappear.

**Verify:** all 6 eval; **Commit:** `refactor(aspects): collapse facts into the module system (pure-membership aspects)`.

---

## P-cards — per-host `host.nix` cards + collection

### 1. Add the per-host collector to the builder

Walk `hosts/<name>/` (readDir, skip `_`-prefixed and non-`.nix`), classify each file:

- a file exposing any of `aspects` / `shared` / `nixos` / `homeManager` is a **card** → route buckets;
- anything else is a **plain nixos module** → nixos eval (function-modules and `{config = …;}` attrsets
  alike — `f ? aspects` is `false` for both, so they pass through). This replaces `inputs.import-tree dir`
  (host dirs are flat, so a shallow readDir matches its semantics).

```nix
isCard = f: f ? aspects || f ? shared || f ? nixos || f ? homeManager;
# aspects     = lib.concatMap (f: f.aspects or []) cards
# shared      -> modules AND home-manager.sharedModules
# nixos       -> modules ;   homeManager -> home-manager.sharedModules
# plain files -> imported by path into modules (unchanged)
```

The builder reads `username` from the card (`card.shared.fireproof.username`) to define
`users.<username>` and `home-manager.users.<username>` (was `resolvedFacts.username`).

### 2. Write each `hosts/<name>/host.nix`

From the matching `targets.<host>` entry, **inlining the host's `_home.nix` body** into the `homeManager`
bucket (then delete `_home.nix`). Example:

```nix
# hosts/desktop/host.nix
{
  aspects = ["workstation" "physical" "nvidia" "chromium" "bambu" "intellij" "clickhouse" "claude-work" "snapcast"];
  shared = {
    fireproof.hostname = "desktop";
    fireproof.username = "nickolaj";
    fireproof.hardware.gpuPciId = "10de:2c05";
    fireproof.monitors = import ./_monitors.nix;
  };
  homeManager = {pkgs, lib, ...}: {
    home.packages = [pkgs.unstable.runelite];
    programs.ssh.settings."bastion.ao" = {HostName = "62.199.221.53"; ProxyJump = lib.mkForce null;};
  };
}
```

The host's nixos-only `default.nix` stays a plain auto-collected sibling. `_monitors.nix` stays a
`_`-skipped data fragment, imported by `shared`.

### 3. Point `mkSystem` at the collector

Instead of `targets.<host>.{aspects,facts,homeModules}`. `targets` is reduced to a bare name→dir map
(deleted in P-discovery). `mkHome`/portability-check are untouched — they pass `aspects`/`facts`
explicitly.

**Verify:** all 6 eval. **Commit:** `refactor(hosts): per-host host.nix cards + collection`.

---

## P-discovery — marker-file discovery, delete `targets`

### 1. Discover by marker file — a host is a folder containing `host.nix`

```nix
isHost    = name: type: type == "directory" && builtins.pathExists (./. + "/${name}/host.nix");
hostNames = lib.attrNames (lib.filterAttrs isHost (builtins.readDir ./.));
```

`bootstrap/` (no `host.nix`) and `_templates/` are excluded for free.

### 2. Build from discovery

```nix
config.flake.nixosConfigurations =
  lib.genAttrs hostNames buildHost
  // {bootstrap = buildBootstrap null;}
  // lib.listToAttrs (map (n: lib.nameValuePair "bootstrap-${n}" (buildBootstrap n)) hostNames);

config.flake.aspects = lib.genAttrs hostNames (n: {aspects = …; closure = …; leaves = …;});
```

`bootstrap-<name>` only bakes the name string into the ISO (`_bake.nix`); it never builds the target's
config, so the name list is all it needs. **Delete the `targets` attrset.**

### 3. `just new-host` + docs

`just new-host` drops a `hosts/<name>/host.nix` from a template (with `aspects`/`shared`) instead of the
old `default.nix` + a `targets` edit. Update `AGENTS.md`: adding a host is now "create the folder + its
`host.nix`"; remove the `targets`/`facts` concepts from the architecture section and document the card
shape, the collector, and the trimmed bundle adjacency (bundles lists only composing nodes; pass-through
aspects resolve via `or []`).

**Verify:** discovered set == the 6 hosts; all eval + package-set parity; `bootstrap` + each
`bootstrap-<name>` eval; portability-check; `just check`. **Commit:**
`refactor(hosts): marker-file discovery, drop central targets`.

---

## Net result

Deleted: `lib/aspects.nix:facts`; every bundle `.facts` + the `facts` submodule field; ~13 vestigial/dead
`fireproof.*` options; the `targets` registry and its `homeModules` plumbing; the per-host `_home.nix`
files. `aspects.nix` is a ~6-line composition graph. "Fact" stops being a concept — it is an option set
in a `shared` (or aspect-tagged) module. Each `hosts/<name>/` is self-describing via its `host.nix` card.

## Activate

The finished system is already running. These phases are parity-clean, so `just diff <h>` shows nothing
and a final `just switch <h>` is a closure no-op — verification is the real gate; activation is a
formality.
