{
  flake.modules.nixos.comma = _: {programs.nix-index-database.comma.enable = true;};
  flake.modules.darwin.comma = _: {programs.nix-index-database.comma.enable = true;};
}
