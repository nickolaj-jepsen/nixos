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
      "https://niri.cachix.org"
    ];

    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "fnug.cachix.org-1:SDUeF2nZSbSPOAMNJdYZdoVB+tHdB8UHHcqhEmizeNk="
      "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
    ];
  };
}
