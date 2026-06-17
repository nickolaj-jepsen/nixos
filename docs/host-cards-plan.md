# Host cards + facts collapse — plan

Status: **planned, pure-Nix, no YubiKey.** Assumes `dendritic-finish-plan.md` is fully
applied: no `fireproof.home-manager` alias, the four secret leaves (ssh/k8s/mcp/spotify)
are dendritic HM agenix-rekey leaves living in their aspect folders, `wrapAspect` is the
folder-stamping branch only, the central `aspectTags` block is gone, and all hosts have
switched. This plan removes the two remaining warts: the **`facts` data-merge layer** and
the **central `targets` registry**. Each host folder ends up describing its own aspects and
its own config, like every other dendritic module.

Every step is **config-preserving** and provable by the migration's existing per-host
**package-set parity** gate — no hardware, no rebuild required beyond eval/build.

Order: **P-facts → P-cards → P-discovery.** Each phase is independently verifiable; commit
after each. The branch stays switchable throughout.

## Why

- A "fact" is just a `fireproof.*` option value. Those options are emitted to **both** module
  classes (`fireproof-options.nix`), so any module touching only `fireproof.*` is class-agnostic
  and can be imported into both evals — and the NixOS module system already merges option values
  with real precedence. The `facts` resolver (`lib/aspects.nix`: `recursiveUpdate`/`foldl'` +
  `{fireproof = resolvedFacts;}` injection) is a weaker parallel merge engine running beside the
  real one. Delete it.
- An **aspect** then needs to carry no data — it is a pure membership tag. The bundle DAG collapses
  to a ~5-line adjacency list.
- A **host** stops being a central `targets.<h> = {dir; aspects; facts; homeModules;}` entry and
  becomes a `hosts/<h>/host.nix` card colocated with the rest of its folder; the fleet is
  discovered, not enumerated.

## Verification (same gates the migration already used)

- `nix eval .#nixosConfigurations.<h>.config.system.build.toplevel.drvPath` — eval each of the 6 hosts.
- **package-set parity** — sorted `environment.systemPackages` + `home-manager.users.<u>.home.packages`
  outPaths, before vs after each phase. This is THE gate: a pure refactor must not move a single outPath.
- `nix build .#homeConfigurations.portability-check.activationPackage` — standalone HM still builds.
- `just aspects <h>` — resolved aspects / closure / leaves unchanged.

---

## P-facts — collapse facts into the module system

Parity-preserving because every option a bundle's `facts` used to set is either **relocated to a
tiny leaf** (the few load-bearing flags) or **deleted** (vestigial flags with zero readers).

### Steps

1. **Make `flake.bundles` pure adjacency.** In `aspects.nix`, change the option to
   `lib.types.lazyAttrsOf (lib.types.listOf lib.types.str)` and drop the `facts` field entirely.
   `config.flake.bundles` shrinks to only the nodes that _compose_ — every other aspect is a
   pass-through name the closure carries via `or []`:

   ```nix
   config.flake.bundles = {
     desktop     = ["windowManager"];
     laptop      = ["physical"];
     gui-dev     = ["desktop" "dev"];
     gui-work    = ["desktop" "work"];
     workstation = ["gui-dev" "gui-work"];
   };
   ```

   In `lib/aspects.nix`: `closure` reads `bundles.${n} or []` (was `bundles.${n}.includes or []`);
   **delete the `facts` function**; keep `closure` + `selectedLeaves`.

2. **Relocate the load-bearing capability flags** to tiny class-agnostic leaves. After the finish
   plan these four are still read by _always-present_ modules, so membership alone can't carry them
   (confirm the reader set per flag with `grep -rn 'fireproof\.<flag>' modules`):

   | flag              | read by (always-present)                                        | setter                                |
   | ----------------- | --------------------------------------------------------------- | ------------------------------------- |
   | `desktop.enable`  | `scripts/default.nix`, `windowManager.enable` default           | new `modules/desktop/enable.nix`      |
   | `work.enable`     | `secrets/ssh.nix` (work secret/host bits)                       | new `modules/work/enable.nix`         |
   | `hardware.laptop` | `battery`/`wifi`/`dimmableBacklight` defaults, `control-center` | new `modules/laptop/enable.nix`       |
   | `wsl.enable`      | `hardware.physical` default (`!wsl.enable`)                     | set inside existing `modules/wsl.nix` |

   Each is dual-declared (so both evals see it) and folder-tagged into its aspect:

   ```nix
   # modules/desktop/enable.nix  -> folder stamps aspectTags.desktop-enable = ["desktop"]
   let m = {fireproof.desktop.enable = true;};
   in {
     flake.modules.nixos.desktop-enable = m;
     flake.modules.homeManager.desktop-enable = m;
   }
   ```

   (`hardware.physical`/`hardware.zram` stay as derived option defaults off `wsl.enable`/`laptop`;
   nothing sets them directly, so they need no setter.)

3. **Delete the vestigial flags** — zero readers, so removing the option + its bundle fact changes
   nothing observable. Confirm each with grep; the parity gate catches a miss. After the finish plan
   (mcp/k8s/spotify/immich now membership-gated) these have no consumers:

   `desktop.chromium.enable`, `desktop.bambu-studio.enable`, `desktop.google-chrome.enable`,
   `claude-code.work.enable`, `dev.intellij.enable`, `dev.clickhouse.enable`, `hardware.nvidia.enable`,
   `desktop.windowManager.enable`, `dev.enable`, `homelab.enable`.

   Remove each from `fireproof-options.nix`. Their aspects (`chromium`, `nvidia`, `intellij`, …) keep
   working as **pure tags**: the leaves (`modules/chromium.nix` → tag `["chromium"]`, etc.) are already
   selected by membership, never by the flag.

4. **Simplify the fact injection.** In `mkSystem` (`hosts/default.nix`),
   `resolvedFacts = aspectsLib.facts …` becomes the host's own facts; inject `{fireproof = host.facts;}`
   into both evals as today (no bundle merge). In `lib/mkHome.nix`,
   `resolvedFacts = facts // {inherit username;}` injected directly. Both `aspectsLib.facts` call sites
   disappear.

**Verify:** all 6 eval + package-set parity; portability-check builds; `just aspects <h>` closures
unchanged. **Commit:** `refactor(aspects): collapse facts into the module system (pure-membership aspects)`.

---

## P-cards — per-host `host.nix` cards + collection

### Steps

1. **Add the per-host collector** to the builder. Walk `hosts/<name>/` (readDir, skip `_`-prefixed and
   non-`.nix`), and classify each file:
   - a file exposing any of `aspects` / `shared` / `nixos` / `homeManager` is a **card** → route buckets;
   - anything else is a **plain nixos module** → nixos eval, exactly as today (function-modules and
     `{config = …;}` attrsets alike — `f ? aspects` is `false` for both, so they pass through).

   ```nix
   isCard = f: f ? aspects || f ? shared || f ? nixos || f ? homeManager;
   # aspects     = lib.concatMap (f: f.aspects or []) cards
   # shared      -> modules AND home-manager.sharedModules
   # nixos       -> modules ;   homeManager -> home-manager.sharedModules
   # plain files -> imported by path into modules (unchanged)
   ```

2. **Write each `hosts/<name>/host.nix`** from the matching `targets.<host>` entry. Example:

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
     homeManager = {pkgs, ...}: {home.packages = [pkgs.unstable.runelite];};  # was targets.homeModules (P-host-hm)
   }
   ```

   The host's nixos-only `default.nix` stays a plain auto-collected sibling (augment model). Work's
   firefox-homepage HM bit → work's `homeManager` bucket. `_monitors.nix` stays a `_`-skipped data
   fragment, imported by the `shared` bucket.

3. **Point `mkSystem` at the collector** instead of `targets.<host>.{aspects,facts,homeModules}`.
   `targets` is reduced to a bare name→dir map (deleted in P-discovery). `mkHome`/portability-check are
   untouched — they pass `aspects`/`facts` explicitly.

**Verify:** all 6 eval + package-set parity (the runelite / work-firefox HM bits must land identically);
portability-check. **Commit:** `refactor(hosts): per-host host.nix cards + collection`.

---

## P-discovery — marker-file discovery, delete `targets`

### Steps

1. **Discover by marker file** — a host is a folder containing `host.nix`:

   ```nix
   isHost    = name: type: type == "directory" && builtins.pathExists (./. + "/${name}/host.nix");
   hostNames = lib.attrNames (lib.filterAttrs isHost (builtins.readDir ./.));
   ```

   `bootstrap/` (no `host.nix`) and `_templates/` are excluded for free.

2. **Build from discovery:**

   ```nix
   config.flake.nixosConfigurations =
     lib.genAttrs hostNames buildHost
     // {bootstrap = buildBootstrap null;}
     // lib.listToAttrs (map (n: lib.nameValuePair "bootstrap-${n}" (buildBootstrap n)) hostNames);

   config.flake.aspects = lib.genAttrs hostNames (n: {aspects = …; closure = …; leaves = …;});
   ```

   `bootstrap-<name>` still only bakes the name string into the ISO (`_bake.nix`); it never builds the
   target's config, so the name list is all it needs. **Delete the `targets` attrset.**

3. **`just new-host`** drops a `hosts/<name>/host.nix` from a template instead of instructing a
   `targets.<host>` edit; update `AGENTS.md` (remove the "add a `targets.<host>` entry" step — adding a
   host is now: create the folder + its `host.nix`).

**Verify:** discovered set == the 6 hosts; all eval + package-set parity; `bootstrap` + each
`bootstrap-<name>` eval; portability-check; `just check`. **Commit:**
`refactor(hosts): marker-file discovery, drop central targets`.

---

## Net result

Deleted: `lib/aspects.nix:facts`; every bundle `.facts` + the `facts` submodule field; ~10 vestigial
`.enable` options in `fireproof-options.nix`; the `targets` registry and its `homeModules` plumbing.
`aspects.nix` is a ~5-line composition graph. "Fact" stops being a concept — it is an option set in a
`shared` (or aspect-tagged) module. Each `hosts/<name>/` is self-describing.

## Activate

The finished system is already running (P-switch, assumed). These phases are parity-clean, so
`just diff <h>` shows nothing and a final `just switch <h>` is a closure no-op — verification is the
real gate; activation is a formality.
