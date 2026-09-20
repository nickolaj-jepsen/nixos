{inputs, ...}: {
  flake.modules.nixos.comma = _: {
    imports = [inputs.nix-index-database.nixosModules.nix-index];
    programs.nix-index-database.comma.enable = true;
  };
  flake.modules.darwin.comma = _: {
    imports = [inputs.nix-index-database.darwinModules.nix-index];
    programs.nix-index-database.comma.enable = true;
  };
}
