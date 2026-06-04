{config, ...}: {
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

    # Free Nix store space on-demand mid-build before hitting ENOSPC,
    # independent of the periodic age-based GC in gc.nix.
    min-free = 3221225472; # start freeing when < 3 GB free
    max-free = 8589934592; # stop after ~8 GB freed

    # Global retry count (Nix has no per-substituter setting). Default is 5,
    # which spams warnings when attic.${config.fireproof.homelab.domain} is down.
    # 3 = two retries, then give up.
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
}
