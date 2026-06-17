# Dendritic migration — finish plan (YubiKey + switch)

Status: **branch `dendritic`, 14 commits, verified.** The migration is functionally
complete and switchable — all 6 hosts build identical to the pre-migration baseline,
and the four secret features still work via the `fireproof.home-manager` alias. This
plan covers the remaining cleanup, which needs a physical YubiKey (`just secret-rekey`)
and `just switch`, to reach the fully-clean end state (no alias, no shim).

Order matters: **P-secrets → P-host-hm → P-alias → P-shim → P-switch**. Each phase is
independently verifiable; commit after each.

Verification helpers used below (already proven during the migration):

- `just aspects <host>` — show a host's resolved aspects / bundle closure / leaves.
- `nix eval .#nixosConfigurations.<h>.config.system.build.toplevel.drvPath` — eval a host.
- `nix build .#homeConfigurations.portability-check.activationPackage` — standalone HM.
- per-host package-set parity (the gate used throughout): compare sorted
  `environment.systemPackages` + `home-manager.users.<u>.home.packages` outPaths before/after.
- `just diff <host>` (nvd) once on real hardware as the final behaviour gate.

---

## P-secrets — move ssh / k8s / mcp / spotify to HM-side agenix-rekey

**Why:** these four leaves are the only ones still legacy. Their home-manager config
references `config.age.secrets.<name>.path`, which today only resolves because the
embedded HM eval can see the NixOS `config.age`. Declaring those secrets HM-side makes
the leaves `osConfig`-free (the last no-bridge gap) and lets the alias be deleted.

**Canonical mechanism:** `git show ad5477e` — that commit migrated *exactly* these
secrets (`spotify-player`, `k8s-ao-{dev,prod}`, `grafana-mcp-env`, the user half of
`ssh-key{,-ao}`) to HM agenix-rekey. Reuse the secret declarations and the
`inputs.agenix.homeManagerModules.default` + `inputs.agenix-rekey.homeManagerModules.default`
wiring verbatim. The one adaptation: that branch *mirrored* `age.rekey` from `osConfig`;
in the dendritic/no-bridge design the HM side computes it from the `hostname` fact instead
(see below), so no osConfig read.

Secrets to move (NixOS `age.secrets` → HM `age.secrets`):

| Leaf | secrets | HM read site |
| --- | --- | --- |
| `system/ssh.nix` | `ssh-key`, `ssh-key-ao` (work) | `programs.ssh.settings.*.IdentityFile` |
| `programs/k8s.nix` | `k8s-ao-dev`, `k8s-ao-prod` | `KUBECONFIG` sessionVariable |
| `programs/mcp.nix` | `grafana-mcp-env` | env-file in a wrapper |
| `programs/spotify.nix` | `spotify-player` | spotify-player config |

Key fact (from ad5477e): the user's `~/.ssh/id_ed25519` is the *same* private key as the
host's `/etc/ssh/ssh_host_ed25519_key` (both rekeyed to the host pubkey from
`secrets/hosts/<host>/id_ed25519.age`), and the rekeyed-secret store
`secrets/hosts/<host>/.rekey/` is shared between the NixOS and HM contexts. So the existing
`.age` files decrypt fine from HM activation; a rekey just (re)generates the HM-named entries.

### Steps

1. **Add an HM agenix-rekey base module** — `modules/base/hm-secrets.nix`, a dendritic
   homeManager-only leaf tagged `["base"]`:
   ```nix
   {
     flake.aspectTags.hm-secrets = ["base"];
     flake.modules.homeManager.hm-secrets = {config, ...}: {
       imports = [
         inputs.agenix.homeManagerModules.default        # via _module.args / specialArgs (inputs)
         inputs.agenix-rekey.homeManagerModules.default
       ];
       # Compute the rekey identity from the hostname FACT (no osConfig), mirroring
       # modules/base/secrets.nix: hostPubkey = readFile secrets/hosts/<hostname>/id_ed25519.pub,
       # masterIdentities = [yubikey-identity.pub], extraEncryptionPubkeys = [bitwarden],
       # localStorageDir + generatedSecretsDir = secrets/hosts/<hostname>{/.rekey,}.
       age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];  # same key, user-readable? see note
       age.rekey = { ... };
     };
   }
   ```
   - `inputs` reaches HM modules via `home-manager.extraSpecialArgs` (already set in the
     builder) — reference it there, or pass the two modules from the builder/mkHome instead
     of `imports` if `inputs` isn't in scope inside the leaf.
   - **identityPaths note:** HM activation runs as the user and must read the identity to
     decrypt at runtime. `/etc/ssh/ssh_host_ed25519_key` is root-only — confirm how ad5477e
     handled the runtime identity for the user (likely `~/.ssh/id_ed25519`, which is the same
     key). Match it.
2. **Convert the four leaves** to dendritic homeManager leaves (like the others): declare
   `age.secrets.<name> = { rekeyFile = ../../secrets/...; }` in the HM half, read
   `config.age.secrets.<name>.path` locally. For `ssh`, split the always-on base ssh from
   the work-gated bits: tag `ssh` `["base"]`, gate the work secret/host config on the `work`
   fact (`lib.mkIf config.fireproof.work.enable`). Remove their central `aspectTags` entries
   from `aspects.nix`.
3. **mkHome / portability-check:** add the two agenix HM modules + a placeholder
   `age.rekey.hostPubkey` (ad5477e used `age1qyqsz…3290gq`) so the standalone eval doesn't
   need a real host key. The portability-check will then also cover the secret leaves.
4. **Rekey (YubiKey):** `just secret-rekey` — regenerates `secrets/hosts/<host>/.rekey/*`
   for the HM-context secret names (touch YubiKey when prompted).
5. **Verify:** per-host package-set parity vs baseline; `nix build .#homeConfigurations.portability-check.activationPackage`; `just build-system <host>`.

Commit: `refactor(secrets): move ssh/k8s/mcp/spotify to HM agenix-rekey`.

---

## P-host-hm — move the two host HM bits off the alias

Two host configs still write `fireproof.home-manager.*`:

- `hosts/desktop/default.nix` — `fireproof.home-manager.home.packages = [pkgs.unstable.runelite]`.
- `hosts/work/default.nix` — `fireproof.home-manager.programs.firefox…homepage = lib.mkForce "…/work"`.

Pick one:

- **(a, recommended) per-host HM hook in the builder.** Add an optional
  `homeModules ? []` to each `targets.<host>` entry and splat it into
  `home-manager.sharedModules` in `mkSystem` (next to the fact injection). Then each host's
  HM bit becomes a small module in the target entry (or a `hosts/<h>/_home.nix` bare module
  `import`ed there). Generalises for future host-specific HM.
- **(b) leaf/fact.** `runelite` → a `runelite` opt-in leaf the desktop host selects; the work
  firefox homepage → a `fireproof.firefox.homepage` option the firefox leaf reads, set as a
  work fact. More moving parts; only worth it if reused.

Verify: package-set parity for desktop + work. Commit.

---

## P-alias — delete the `fireproof.home-manager` alias

Once nothing writes `fireproof.home-manager` (check: `grep -rn 'fireproof\.home-manager' modules hosts`
returns nothing):

1. Delete `modules/base/home-manager.nix` and its `"base/home-manager"` entry in
   `aspects.nix`'s central `aspectTags`.
2. Keep the `home-manager.useUserPackages`/`useGlobalPkgs` + `system.stateVersion`/
   `home.stateVersion` defaults that lived there — move them into a small base module or the
   builder so they survive the deletion.

Verify: all 6 eval + package-set parity; portability-check builds. Commit.

---

## P-shim — collapse the import-tree shim to plain import-tree

Once every file under `modules/` is dendritic (no legacy leaves left — confirm
`config.flake.modules.nixos` has no path-style names like `"system/ssh"`):

1. In `flake.nix`, replace `((inputs.import-tree.map wrapNixos) ./modules)` with
   `(inputs.import-tree ./modules)` and delete the `wrapNixos` shim + the `lib` let-binding
   it needed.
2. Remove the now-empty central `aspectTags` block in `aspects.nix` (all tags are
   per-leaf now). Keep `flake.bundles` + the option declarations.

Verify: all 6 eval + package-set parity; `just check` (runs the portability-check +
orphan checks). Commit.

---

## P-switch — activate

1. `just aspects <host>` to eyeball each host's resolution.
2. `just diff <host>` per host (nvd closure diff vs the running system) — the final
   behaviour gate. Expect no package add/remove/version-change (only the benign
   `home.packages`-ordering rederivations noted in the commits).
3. `just test <host>` (reverts on reboot) to smoke-test, then `just switch <host>`.
4. Roll out the homelab/headless hosts last.

Rollback: the whole migration is on `dendritic`; `git checkout main` + rebuild restores the
pre-migration system. Per generation, `just history` + boot an older generation.

---

## Optional follow-ups (not required)

- Drop the dead `desktop.google-chrome.enable` leaf/option (no host selects it) and the dead
  `dev.playwright.enable` option (no consumer).
- Consider `den` (https://github.com/denful/den) as a drop-in for `lib/aspects.nix` if it
  stabilises past 1.0 — the bundle data is already shaped like its `includes` model.
- A real standalone-HM or nix-darwin host: add `flake.hosts`-style entries + a `darwinSystem`
  arm; `mkHome` already proves the home-manager half is portable.
