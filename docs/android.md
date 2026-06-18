# Android (`phone`) — nix-on-droid host

The `phone` host runs [nix-on-droid](https://github.com/nix-community/nix-on-droid)
on an Android device: a Nix-managed CLI environment inside a Termux/proot sandbox,
no root and no NixOS. It reuses the same dendritic `homeManager` leaves as the rest
of the fleet — so it's effectively `dev-ao` (the headless dev server) but on Android:
fish, neovim, git, claude-code, direnv, zellij, and the personal dev CLI.

It targets **aarch64-linux** and has **no systemd**, so it builds and activates
**on the device**, not from your desktop.

## How it fits the repo

- `hosts/phone/host.nix` is a `class = "droid"` [host card](../AGENTS.md#host-cards-fireproof).
  `class` routes the whole host through `buildDroid` (in `hosts/default.nix`), which
  calls `nix-on-droid.lib.nixOnDroidConfiguration` and routes every
  `flake.modules.homeManager.*` leaf into nix-on-droid's embedded home-manager.
- The card has three buckets:
  - `shared` — `fireproof.*` facts (toggles). Lean & personal: `dev.enable = true`
    with the work/GUI-bound extras (`dev.k8s`, `dev.mcp`, `dev.clickhouse`,
    `dev.playwright`, `dev.intellij`) off.
  - `droid` — the nix-on-droid **system** config (`user.shell`, `time.timeZone`,
    `system.stateVersion`, `nix.extraOptions`).
  - `homeManager` — per-host HM tweaks (here: pin `claude-code` to the multi-arch
    build, see [claude-code](#claude-code-on-aarch64)).
- Output: `nixOnDroidConfigurations.phone`.

Because it enables no secret-consuming toggles, the phone declares **zero** agenix
secrets — only its public key (`secrets/hosts/phone/id_ed25519.pub`) is committed,
and the always-on `ssh`/`hm-secrets` leaves stay inert.

## First-time install (on the device)

1. Install **Nix-on-Droid** from
   [F-Droid](https://f-droid.org/packages/com.termux.nix/) (not the Play Store
   build) and open it once — it bootstraps a proot sandbox with Nix.
2. Apply this flake's `phone` config:
   ```bash
   nix-on-droid switch --flake github:nickolaj-jepsen/nixos#phone
   ```
   The first build is **slow**: nix-on-droid compiles a fair amount from source
   under proot (see [First build is slow](#first-build-is-slow)).
3. Restart the nix-on-droid shell. `fish` is now the login shell and the full CLI
   environment is available.

## Day-to-day

After the first activation `git` and `just` are present, so clone the repo and use
the wrapper for subsequent rebuilds:

```bash
git clone https://github.com/nickolaj-jepsen/nixos ~/nixos
cd ~/nixos
just droid-switch          # = nix-on-droid switch --flake .#phone
```

To pull in upstream changes, update the flake inputs and re-switch:

```bash
cd ~/nixos && git pull
nix flake update           # or: nix flake lock --update-input nixpkgs
just droid-switch
```

`just droid-switch <name>` also takes a host name if you add more droid hosts;
it defaults to `phone`.

## Customizing the phone

Edit `hosts/phone/host.nix` and re-run `just droid-switch`.

- **Toggle features** in the `shared` bucket. Anything gated on `desktop.enable`
  (the GUI apps, niri, IDEs) self-excludes — the phone never sets it. Flip a dev
  sub-toggle on/off, e.g. set `fireproof.dev.k8s.enable = true` to get `kubectl`
  (but read [Secrets](#secrets) first — k8s pulls rekeyed secrets).
- **Add packages** the n-o-d system way (always present, even pre-HM) via the
  `droid` bucket:
  ```nix
  droid = {pkgs, ...}: {
    environment.packages = [pkgs.ripgrep pkgs.htop];
    # ...existing settings
  };
  ```
  or the home-manager way (preferred for personal tools) by editing/adding a
  `homeManager` leaf — same as any other host.
- **Change the login shell** via `user.shell` in the `droid` bucket.

### claude-code on aarch64

The fleet's `claude-code` overlay (`overlays/claude-code.nix`) pins an **x86-64**
prebuilt binary — its `overlayAttrs` are computed on the x86 build host and applied
verbatim to the aarch64 pkgs, so `pkgs.claude-code` would be a wrong-arch ELF on the
phone. The phone card overrides it to the stock multi-arch nixpkgs build:

```nix
homeManager = {pkgs, lib, ...}: {
  programs.claude-code.package = lib.mkForce pkgs.unstable.claude-code;
};
```

If you later make the overlay arch-aware (select `linux-arm64` by
`final.stdenv.hostPlatform.system`), drop this override.

## Secrets

agenix-rekey discovers nodes from `nixos`/`home` configs only — **not**
`nixOnDroidConfigurations` — so the phone's HM rekey node is invisible to
`just secret-rekey`, and a droid host has no NixOS eval to place a decrypt identity.
Therefore:

- Keep the phone **secret-free** (it is). Enabling a secret-consuming toggle
  (`dev.k8s`, `dev.mcp`, `work`, …) will fail to activate, because its rekeyed blob
  is never generated and there's no `~/.ssh/id_ed25519` to decrypt with.
- To make the phone a real secrets peer you'd register the droid HM node with
  agenix-rekey and provision the decrypt key on-device out-of-band (as `dev-ao`
  does with its RSA key).
- The phone's host **private** key was generated during setup and stashed at
  `~/.ssh/nix-on-droid-phone-host_ed25519` on the desktop. You only need to move it
  to the device if you take the secrets-peer route; the committed `.pub` is enough
  for the current secret-free config.

## Adding another droid host

`just new-host` doesn't scaffold droid hosts. Create `hosts/<name>/host.nix` with
`class = "droid"`, a `shared` bucket of facts, and a `droid` bucket (copy `phone`'s).
Commit a `secrets/hosts/<name>/id_ed25519.pub` (generate a keypair; keep the private
half off-repo) so the always-on `ssh`/`hm-secrets` leaves resolve. The host is
discovered automatically — no `hosts/default.nix` edit. Build it on the device with
`just droid-switch <name>`.

## Troubleshooting

### First build is slow

neovim compiles ~25 tree-sitter parsers plus a stack of language servers/formatters
from source, all under proot. Everything is aarch64-supported (nothing broken), it's
just CPU/RAM-heavy and can crawl or OOM on a phone. The real fix is a binary cache:
point an aarch64 builder (or a `nix copy` from a beefier machine) at a cachix/own
substituter and let the phone substitute instead of compile.

### `git commit -S` fails

`git.nix` configures SSH commit signing via `op-ssh-sign` (1Password, desktop-only,
not in the phone closure). Signing is **not** on by default, so this only bites if
you opt into it on the phone — then it fails with `op-ssh-sign: command not found`.

### Dead host-only commands

The always-on `scripts` leaf carries a few host-only helpers onto the phone
(`reboot-windows`, `journalctl-select`, `kctx`) which pull `systemd`/`kubectl` into
the closure and don't function on Android. Harmless, just unused.

### Evaluating from the desktop

`nix eval .#nixOnDroidConfigurations.phone...` needs `--impure` (nix-on-droid uses
fixed bootstrap `storePath`s) and still can't **realize** the closure on x86-64
(aarch64 prebuilts like `proot-termux`). This is expected — the phone builds
on-device. There is intentionally no `just check` / CI build for it.
