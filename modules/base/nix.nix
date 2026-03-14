{
  config,
  pkgs,
  ...
}: {
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    trusted-users = [
      "root"
      "@wheel"
      config.fireproof.username
    ];

    experimental-features = ["nix-command" "flakes"];
    warn-dirty = false;

    substituters = [
      "https://nix-community.cachix.org"
      "https://fnug.cachix.org"
    ];

    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "fnug.cachix.org-1:SDUeF2nZSbSPOAMNJdYZdoVB+tHdB8UHHcqhEmizeNk="
    ];
  };

  # Make 'nix repl' have all the nixpkgs available
  environment.systemPackages = [pkgs.nixpkgs-fmt];
}
