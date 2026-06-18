# Phone aarch64 build cache (deferred)

Status: **not implemented.** This is the follow-up ("Phase B") to the nvf neovim
migration. Phase A (the lean/full neovim split) already removed most of the phone's
build pain by keeping pyrefly, the TypeScript stack, and ~15 tree-sitter grammars
_off_ the phone (see [android.md → First build is slow](./android.md#first-build-is-slow)).
This document is the plan for closing the rest: serve the phone's **aarch64** closure
from the homelab attic so even the lean set substitutes instead of compiling.

## The problem this solves

The phone is `aarch64-linux` and builds **on the device** under proot. Anything not
already on a substituter it trusts gets compiled there, which is slow and can OOM. The
fix the [android doc already names](./android.md#first-build-is-slow) is a binary
cache; this is that, wired to the infra we already run.

Two facts make it a real (if small) build-out, not a flip-a-switch:

1. **CI only builds x86_64.** `.github/workflows/fmt.yml` builds
   `nixosConfigurations.<host>` on `ubuntu-latest` and pushes to the `nixos` attic
   cache. Nothing aarch64 is ever built or pushed, so the phone's closure isn't there.
2. **The phone doesn't trust attic.** The substituter list (`attic.<domain>/nixos` +
   the `nixos:` pubkey) lives in `modules/base/nix.nix`, a `flake.modules.nixos.nix`
   half. The phone is a `droid` host with **no NixOS eval**, so it never sees that
   list — its nix settings come from the `droid` bucket, which today only sets
   `experimental-features`.

## What's already reusable

The push half is done and stays as-is:

- The attic server (`attic.${fireproof.homelab.domain}/nixos`, `modules/homelab/attic.nix`).
- `ATTIC_TOKEN` + `HOMELAB_DOMAIN` repo secrets.
- The `./.github/actions/setup-nix` composite action, which configures attic for
  substitution **and** push when handed `attic-endpoint`/`attic-cache`/`attic-token`
  (it wraps `ryanccn/attic-action`).

So Phase B is two additions.

## Part 1 — an aarch64 build+push CI job

Add a job to `.github/workflows/fmt.yml` on a **native** `ubuntu-24.04-arm` runner
(free for public repos, so no qemu emulation). It builds the phone's aarch64 closure
and pushes whatever it realizes to the `nixos` cache via the existing action.

```yaml
phone:
  needs: [fmt, check]
  runs-on: ubuntu-24.04-arm
  timeout-minutes: 120
  steps:
    - uses: actions/checkout@... # pin like the other jobs
    - uses: ./.github/actions/setup-nix
      with:
        attic-endpoint: https://attic.${{ secrets.HOMELAB_DOMAIN }}/
        attic-cache: nixos
        attic-token: ${{ secrets.ATTIC_TOKEN }}
    - name: Build phone closure
      run: nix build --impure .#nixOnDroidConfigurations.phone.activationPackage
```

`--impure` is required because nix-on-droid pins fixed bootstrap `storePath`s (same
reason `nix eval` of the phone needs it).

### Spike before trusting this

On a non-Android aarch64 runner, the whole `activationPackage` may pull
**Android-only** derivations from nix-on-droid's bootstrap (e.g. `proot-termux`) that
don't build/realize off-device. The desktop can't realize them on x86 either — that's
expected and documented. So before committing the job above, confirm what actually
builds on `ubuntu-24.04-arm`:

- If `activationPackage` realizes cleanly: use it (warms the _entire_ phone closure).
- If it chokes on bootstrap derivations: **narrow the target** to just the expensive,
  device-independent part — the neovim package and its closure (grammars, LSP
  servers). The confirmed accessor (verified by `nix eval --impure` on x86, which
  computes the aarch64 `.drv` without realizing `proot-termux`) is:
  `nixOnDroidConfigurations.phone.config.home-manager.config.programs.nvf.finalPackage`.
  Build that directly, or expose it as an `aarch64-linux` flake output and build the
  output. Caching neovim alone covers the parsers + servers, which is the whole point.

This spike is the one genuinely uncertain piece; everything else is mechanical.

## Part 2 — wire the phone to trust attic

The phone's nix config is the `droid` bucket in `hosts/phone/host.nix`. Add the attic
substituter + public key to its `nix.extraOptions`:

```nix
droid = {pkgs, ...}: {
  # ...existing user.shell / time.timeZone / stateVersion...
  nix.extraOptions = ''
    experimental-features = nix-command flakes
    extra-substituters = https://attic.nickolaj.com/nixos
    extra-trusted-public-keys = nixos:yGPW0JSJw+piW/f/7XwmwMdnzz2mUEA8b4Zcco80wkI=
  '';
};
```

Notes:

- The URL/key are hardcoded here because the `droid` system eval has no `fireproof.*`
  (those options live in the embedded-HM eval, not the n-o-d system eval). The values
  must match `modules/base/nix.nix` — if the homelab domain or signing key ever
  changes, update both. (A shared constant readable by both evals would avoid the
  drift; out of scope for the first cut.)
- nix-on-droid is single-user, so the user's own `nix.conf` substituters are trusted
  without a `trusted-users` dance.

## Order of operations

1. Land Phase A (lean phone neovim) — already shrinks the closure.
2. Spike the aarch64 build target (Part 1, "Spike") locally: the `work` host has
   `boot.binfmt.emulatedSystems = ["aarch64-linux"]`, so you can
   `nix build --impure .#nixOnDroidConfigurations.phone.activationPackage` there under
   emulation to see what realizes before wiring CI.
3. Add the CI job (Part 1) once the target is known-good.
4. Add the phone's attic trust (Part 2) and re-`just droid-switch` on the device; the
   next build should substitute the warm closure instead of compiling.

## Why this is optional

Phase A stands on its own: a lean phone neovim builds fast even on a cache miss because
the Rust LSP (pyrefly) and the heavy grammar set never reach it. Phase B turns "fast
enough" into "instant substitution" and is worth doing only if the post-Phase-A phone
build is still annoying in practice.
