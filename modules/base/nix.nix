# nix daemon settings shared by nixos + nix-darwin hosts.
let
  # Binary caches + their keys, shared by the nixos `nix.settings` path and the
  # darwin path (which writes them into Determinate's /etc/nix/nix.custom.conf).
  mkCaches = config: {
    substituters = [
      "https://attic.${config.fireproof.homelab.domain}/nixos"
      "https://nix-community.cachix.org"
      "https://fnug.cachix.org"
      "https://niri.cachix.org"
      "https://0xcbmedia.cachix.org"
      "https://pi.cachix.org"
    ];

    trusted-public-keys = [
      "nixos:yGPW0JSJw+piW/f/7XwmwMdnzz2mUEA8b4Zcco80wkI="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "fnug.cachix.org-1:SDUeF2nZSbSPOAMNJdYZdoVB+tHdB8UHHcqhEmizeNk="
      "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
      "0xcbmedia.cachix.org-1:u8PfgqbbO/hjnsA77TCxi5w7hh82dApsqJ4bAgg9Rmo="
      "pi.cachix.org-1:lGeoGJaZ5ZDabuRzkcD5EBTNnDM4HJ1vqeOxlWk1Flk="
    ];
  };

  mkSettings = config:
    mkCaches config
    // {
      trusted-users = [
        "root"
        "@wheel"
        config.fireproof.username
      ];

      experimental-features = ["nix-command" "flakes"];
      warn-dirty = false;

      download-buffer-size = 524288000;
      max-substitution-jobs = 32;

      # Free store mid-build before ENOSPC, independent of gc.nix age-based GC.
      min-free = 3221225472;
      max-free = 8589934592;

      # Global only (Nix has no per-substituter retry); default 5 spams warnings when attic is down.
      download-attempts = 3;
    };
in {
  flake.modules.nixos.nix = {config, ...}: {
    nixpkgs.config.allowUnfree = true;
    nix.settings = mkSettings config;
  };

  # The Mac runs Determinate Nix, which owns the daemon + /etc/nix/nix.conf, so
  # nix-darwin stands down (`nix.enable = false`) and `nix.settings` is inert.
  # Determinate's nix.conf `!include`s nix.custom.conf, so the shared caches/keys
  # go there instead. Writing them as a system file means the daemon honors them
  # for everyone — the work user is not in Determinate's default trusted-users
  # ([root]), so plain user-supplied substituters would otherwise be ignored.
  flake.modules.darwin.nix = {
    config,
    lib,
    ...
  }: let
    caches = mkCaches config;
    line = key: vals: "${key} = ${lib.concatStringsSep " " vals}";
  in {
    nixpkgs.config.allowUnfree = true;
    nix.enable = false;
    environment.etc."nix/nix.custom.conf".text = lib.concatStringsSep "\n" [
      (line "extra-substituters" caches.substituters)
      (line "extra-trusted-substituters" caches.substituters)
      (line "extra-trusted-public-keys" caches.trusted-public-keys)
      (line "extra-trusted-users" ["@admin" config.fireproof.username])
      "download-buffer-size = 524288000"
      "max-substitution-jobs = 32"
      "min-free = 3221225472"
      "max-free = 8589934592"
      "download-attempts = 3"
      ""
    ];
  };
}
