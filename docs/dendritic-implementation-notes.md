# Dendritic / aspects — implementation notes & lessons

Companion to [`unified-migration-plan.md`](./unified-migration-plan.md) (the original
plan) and [`dendritic-finish-plan.md`](./dendritic-finish-plan.md) (the remaining
YubiKey-gated work). This file is the **tribal knowledge** a future agent needs before
touching the aspects/dendritic machinery — the load-bearing decisions, the gotchas that
cost real time to find, and the verification method that proved each step safe. The
authoritative _how-to-author_ reference is `AGENTS.md`; this is the _why_ and the _traps_.

> Status (2026-06-18, branch `dendritic`): the migration is **functionally complete and
> switchable** — all 6 hosts build identical to the pre-migration baseline. The tree is on
> the **folder = aspect** model (commit `4d4d92d`). What's left is the YubiKey finish
> (`dendritic-finish-plan.md`) + `just switch`. The plan doc is now partly historical; trust
> the code + `AGENTS.md` + this file where they disagree with the plan's sketch.

## The load-bearing decisions (don't relitigate without reading these)

- **No `osConfig` bridge.** Facts are resolved at the _flake_ layer (`lib/aspects.nix`) and
  injected into BOTH evals — `{ fireproof = facts; }` goes into `nixosSystem.modules` AND
  `home-manager.sharedModules` (`hosts/default.nix`). The home-manager eval never reads
  `osConfig`. This is what makes embedded (per-host), standalone (`mkHome` /
  `portability-check`), and a future nix-darwin home identical. The earlier `hm-refactor`
  branch's self-adjusting bridge + `propagatedFireproof` mirror are **both gone on purpose**.
- **Official flake-parts `modules` extra**, not a hand-rolled schema:
  `flake.modules.{nixos,homeManager}.<name>` (via `inputs.flake-parts.flakeModules.modules`).
  `import-tree` runs at the flake level.
- **Aspects = a small bundle DAG + membership.** `aspects.nix` declares `flake.bundles`
  (each bundle names other bundles it `includes` and the `fireproof.*` `facts` it sets) and
  `flake.aspectTags` (leaf → bundles). `lib/aspects.nix` is a ~20-line transitive-closure
  resolver, deliberately shaped like [`den`](https://github.com/denful/den)'s `includes`
  model for a possible drop-in later. A host lists _aspects_, never toggles.
- **Membership, not `mkIf`.** A leaf applies because it's _selected_, not because a toggle is
  true. Intra-module conditionals on _facts_ (`lib.optional config.fireproof.hardware.battery`)
  are fine — those are parameters, not membership gates.
- **folder = aspect** (commit `4d4d92d`). The directory a leaf lives in _is_ its membership;
  `wrapAspect` in `flake.nix` stamps `flake.aspectTags.<name> = [<folder>]`. See `AGENTS.md`.

## Gotchas you WILL hit (each cost real time)

1. **The no-bridge fact-flow is load-bearing — and it bites in a specific order.** Converting
   a home-manager leaf to `flake.modules.homeManager.<name>` while keeping its
   `mkIf config.fireproof.desktop.enable` makes the gate evaluate **false** in the HM eval —
   because the host historically set `desktop.enable` on the _NixOS_ side only, and the HM eval
   sees the option default. HM-leaf conversion is therefore **blocked until facts flow into the
   HM eval**. (NixOS leaves convert fine incrementally; they read facts the host already sets
   nixos-side.) Build the fact-flow before converting HM leaves.
2. **Conditionals on `imports` = infinite recursion.** `lib.optionals cfg.foo [ ./x.nix ]` (or
   any `config`-dependent `imports`) triggers Nix's "you probably reference config in imports"
   recursion. Use **unconditional** `imports`; the upstream HM modules are enable-gated and
   inert when unused (dms/default, dms/plugins, niri/dynamic-workspaces were the offenders).
3. **Only `claude-code` read across the eval boundary.** It used
   `config.home-manager.users.${u}.programs.claude-code.{finalPackage,lib,home.homeDirectory}`
   — rewritten to local `config.programs.claude-code.*` / `config.lib.*` / `config.home.*` in
   the HM half. Every other HM leaf just relocates its block verbatim. If you add a leaf that
   reaches into `config.home-manager.users.*`, you've reintroduced the bridge — don't.
4. **"Deleting toggles" is entangled; the committed state IS the clean end.** `desktop.enable`
   etc. can't simply be removed: option _defaults_ read them (e.g. `windowManager.enable`
   defaulted to `desktop.enable`), intra-module fact reads need them (`ssh`→`work.enable`,
   `dms`→`hardware.battery`, `nvidia`→`hardware.nvidia.enable`), and bundle `facts` set them.
   So "delete toggles" realistically means **toggles became bundle-set facts** (users select
   aspects). That is already done. Removing a leaf's outer `mkIf` is pure cleanliness
   (redundant with membership), not a correctness change.
5. **`flake.modules.<class>` is one FLAT, GLOBAL namespace.** The module _name_ is the
   resolver's join key and must be unique across the whole tree. Real collisions already
   resolved: `programs/postgres`→`postgres-cli` (vs `homelab/postgres`→`postgres`),
   `homelab/security`→`homelab-security` (vs `system/security`→`security`). Folder = aspect
   does **not** make names unique — you still hand-name each module.
6. **folder = aspect has a silent-inert failure mode.** Because membership is _location_, a
   file dropped in the wrong (or an unwired) folder is simply never selected — **no error**.
   There is no orphan check yet (recommended follow-up: add one to `just check` that flags any
   aspect folder unreachable from a host). Mistrust "it built fine" for _additions_; confirm
   the leaf shows up in `just aspects <host>`.

## Verification method (use this for every change — it's what made the migration safe)

Every step was proven **behavior-neutral** against a captured baseline, in rough order of
strength:

- **`toplevel.drvPath` equality** (strongest): capture per-host
  `nix eval --raw .#nixosConfigurations.<h>.config.system.build.toplevel.drvPath` on the
  baseline commit, then re-eval after the change. A pure refactor (renames, folder moves, the
  wrapper swap) must be **byte-identical**. Used for the folder=aspect reorg — identical on all
  6 hosts.
- **Sorted package-set parity**: compare sorted `environment.systemPackages` +
  `home-manager.users.<u>.home.packages` outPaths. Use when drvPath legitimately changes but
  the _content_ shouldn't (e.g. list reordering).
- **home.file fingerprint**: the set of managed file names + each file's content. Catches HM
  regressions a package-set check misses.
- **Standalone**: `nix build .#homeConfigurations.portability-check.activationPackage`
  (`osConfig = null`) proves the HM half is bridge-free / portable.

**Known-benign non-determinism:** `config.fish`, `fontconfig`, fish completions, and `manpath`
can differ purely by `home.packages` list **reordering** (confirmed a pure line-reorder, not a
content change). Don't chase these — confirm it's only ordering and move on.

## Facts about this config that aren't obvious from a quick read

- **Current host aspects** (`hosts/default.nix`):
  - `desktop` = `workstation physical nvidia chromium bambu intellij clickhouse claude-work snapcast`
  - `laptop` = `workstation laptop chromium intellij clickhouse`
  - `work` = `workstation physical nvidia chromium intellij clickhouse claude-work`
  - `homelab` = `dev homelab physical clickhouse`
  - `minilab` = `gui-dev physical snapcast oxcb-media` ← gets gui-dev editors, but NOT chromium/intellij/clickhouse
  - `desktop-wsl` = `dev work wsl clickhouse`
- **`homelab-options` must be always-on (tagged `base`, not `homelab`).** `nix.nix` reads
  `fireproof.homelab.domain` (attic substituter) on _every_ host, so the option declarations
  must exist everywhere. It lives in `modules/homelab/default.nix` with an explicit
  `aspectTags=["base"]` override (folder would otherwise tag it `homelab`).
- **The other override:** `modules/desktop/dms/default.nix` tags `windowManager` (the WM-shell
  integration) while the rest of `dms/` is `desktop` chrome. Behavior-neutral today because
  every host with `windowManager` also has `desktop` (`desktop.includes = ["windowManager"]`).
- **Dead options (droppable, behavior-neutral):** `desktop.google-chrome.enable` — the
  `google-chrome` bundle exists but **no host selects it**. `dev.playwright.enable` — declared
  in `fireproof-options.nix` but **nothing reads it** (the vscode `ms-playwright.playwright`
  extension is installed unconditionally, not gated by this option).
- **Legacy leaves (the only non-folder-tagged ones):** `system/ssh`, `programs/{k8s,mcp,spotify}`,
  and `base/home-manager` (the `fireproof.home-manager` alias). They're path-registered via
  `wrapAspect`'s legacy `else`-arm and tagged in `aspects.nix`'s central `aspectTags` block.
  They become normal folder-tagged leaves during the YubiKey finish (P-secrets).

## Rejected alternative — don't resurrect it

The `hm-refactor` branch (older `flake.{nixos,home}Modules` schema + a hand-maintained
`propagatedFireproof` mirror + an explicit `imports` list) was **rejected** by the user ("I
wasn't happy with it"). Only its _solved sub-problems_ are reused as mechanism: HM-side
agenix-rekey wiring, the dummy-pubkey trick for standalone eval, `mkHome`, and the secret-file
moves — all in branch commit **`ad5477e`**, which the finish plan's P-secrets reuses verbatim.
