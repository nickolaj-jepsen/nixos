# Standalone home-manager config from all dendritic homeManager leaves (osConfig = null).
{
  inputs,
  lib,
  fpLib,
  flake, # = config.flake
}: {
  system ? "x86_64-linux",
  extraModules ? [], # the host card's `shared` (facts) + `homeManager` (tweaks)
}: let
  homeLeaves = builtins.attrValues flake.modules.homeManager;
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = flake.lib.overlays;
  };
in
  inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {inherit inputs fpLib;};
    modules =
      homeLeaves
      ++ [
        # Standalone must import niri's HM module explicitly and pin niri-unstable to match the embedded path's binary; inert until a host enables niri (safe even on headless dev-ao).
        inputs.niri.homeModules.niri
        ({pkgs, ...}: {programs.niri.package = lib.mkDefault pkgs.niri-unstable;})
        ({config, ...}: {
          # Identity comes from fireproof facts (set via extraModules), so no pre-eval username arg.
          home.username = lib.mkDefault config.fireproof.username;
          home.homeDirectory = lib.mkDefault "/home/${config.fireproof.username}";
          home.stateVersion = lib.mkDefault "24.11";
        })
      ]
      ++ extraModules;
  }
