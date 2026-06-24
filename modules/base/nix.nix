# nix daemon settings shared by nixos + nix-darwin hosts.
let
  nixModule = {config, ...}: {
    nixpkgs.config.allowUnfree = true;

    nix.settings = {
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

      substituters = [
        "https://attic.${config.fireproof.homelab.domain}/nixos"
        "https://nix-community.cachix.org"
        "https://fnug.cachix.org"
        "https://niri.cachix.org"
        "https://0xcbmedia.cachix.org"
      ];

      trusted-public-keys = [
        "nixos:yGPW0JSJw+piW/f/7XwmwMdnzz2mUEA8b4Zcco80wkI="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "fnug.cachix.org-1:SDUeF2nZSbSPOAMNJdYZdoVB+tHdB8UHHcqhEmizeNk="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
        "0xcbmedia.cachix.org-1:u8PfgqbbO/hjnsA77TCxi5w7hh82dApsqJ4bAgg9Rmo="
      ];
    };
  };
in {
  flake.modules.nixos.nix = nixModule;
  flake.modules.darwin.nix = nixModule;
}
