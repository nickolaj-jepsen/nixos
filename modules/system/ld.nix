{
  flake.modules.nixos.ld = _: {
    programs.nix-ld.enable = true;
  };
}
