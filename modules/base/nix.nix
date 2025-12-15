{config, ...}: {
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    trusted-users = [
      "root"
      "@wheel"
      config.fireproof.username
    ];

    experimental-features = "nix-command flakes";
    substituters = [
      "https://nix-community.cachix.org"
      "https://install.determinate.systems"
    ];

    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
    ];
  };
}
