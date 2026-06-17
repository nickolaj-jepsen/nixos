{
  flake.aspectTags.comma = ["base"];
  flake.modules.nixos.comma = _: {programs.nix-index-database.comma.enable = true;};
}
