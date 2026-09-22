# nix daemon settings shared by nixos + nix-darwin hosts.
{
  inputs,
  lib,
  ...
}: let
  # Binary caches + their keys, shared by the nixos `nix.settings` path and the
  # darwin path (which writes them into Determinate's /etc/nix/nix.custom.conf).
  mkCaches = config: let
    # Only llm.nix's CUDA llama-cpp is served from there.
    cuda = config.fireproof.dev.llm.enable;
  in {
    substituters =
      [
        "https://attic.${config.fireproof.homelab.domain}/nixos"
        "https://nix-community.cachix.org"
      ]
      ++ lib.optional cuda "https://cache.nixos-cuda.org";

    trusted-public-keys =
      [
        "nixos:yGPW0JSJw+piW/f/7XwmwMdnzz2mUEA8b4Zcco80wkI="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ]
      ++ lib.optional cuda "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=";
  };

  tuning = {
    download-buffer-size = 524288000;
    max-substitution-jobs = 32;

    # Free store mid-build before ENOSPC, independent of gc.nix age-based GC.
    min-free = 3221225472;
    max-free = 8589934592;

    # Global only (Nix has no per-substituter retry); default 5 spams warnings when attic is down.
    download-attempts = 3;
  };

  mkSettings = config:
    mkCaches config
    // tuning
    // {
      # Trusted = passwordless root-equivalent, so the one deploy user, not all of @wheel.
      trusted-users = [
        "root"
        config.fireproof.username
      ];
      # Puts daemon CVEs out of reach of service users; root is always allowed.
      allowed-users = ["@wheel"];

      experimental-features = ["nix-command" "flakes"];
      warn-dirty = false;
    };
in {
  flake.modules.nixos.nix = {config, ...}: {
    nixpkgs.config.allowUnfree = true;
    nix.settings = mkSettings config;
    # `<nixpkgs>` resolves through the pinned registry instead of a stale channel.
    nix.channel.enable = false;

    # Builds yield CPU/IO to the desktop; `batch` rather than `idle` so a pegged CPU can't starve a rebuild.
    nix.daemonCPUSchedPolicy = "batch";
    nix.daemonIOSchedClass = "idle";
  };

  # The user registry outranks the system one, so pin it too or `nixpkgs#x` drifts from the host.
  flake.modules.homeManager.nix = {
    nix.registry.nixpkgs.flake = inputs.nixpkgs;
  };

  # The Mac runs Determinate Nix, which owns the daemon + /etc/nix/nix.conf, so
  # nix-darwin stands down (`nix.enable = false`) and `nix.settings` is inert.
  # Determinate's nix.conf `!include`s nix.custom.conf, so the shared caches/keys
  # go there instead. Writing them as a system file means the daemon honors them
  # for everyone — the work user is not in Determinate's default trusted-users
  # ([root]), so plain user-supplied substituters would otherwise be ignored.
  flake.modules.darwin.nix = {config, ...}: let
    caches = mkCaches config;
    conf =
      {
        extra-substituters = caches.substituters;
        extra-trusted-substituters = caches.substituters;
        extra-trusted-public-keys = caches.trusted-public-keys;
        extra-trusted-users = ["@admin" config.fireproof.username];
      }
      // tuning;
  in {
    nixpkgs.config.allowUnfree = true;
    nix.enable = false;
    # toString joins lists with spaces, matching nix.conf's list syntax.
    environment.etc."nix/nix.custom.conf".text =
      lib.concatStrings (lib.mapAttrsToList (k: v: "${k} = ${toString v}\n") conf);
  };
}
