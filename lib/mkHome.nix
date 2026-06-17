# Build a standalone home-manager configuration from the dendritic homeManager
# leaves a set of aspects selects — the same leaves and facts the embedded path
# uses, but with no NixOS eval (osConfig = null). This is what a future
# standalone-home-manager or nix-darwin user's home would call; for now its only
# consumer is homeConfigurations.portability-check.
{
  inputs,
  lib,
  fpLib,
  aspectsLib,
  flake, # = config.flake
}: {
  username,
  homeDirectory ? "/home/${username}",
  aspects ? [],
  facts ? {},
  stateVersion ? "24.11",
  system ? "x86_64-linux",
  extraModules ? [],
}: let
  selectedNames = aspectsLib.selectedLeaves flake.bundles flake.aspectTags (["base"] ++ aspects);
  homeLeaves =
    builtins.attrValues
    (lib.getAttrs (builtins.filter (n: flake.modules.homeManager ? ${n}) selectedNames) flake.modules.homeManager);
  resolvedFacts = aspectsLib.facts flake.bundles aspects (facts // {inherit username;});
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
        # niri's home-manager module is auto-shared by the niri NixOS module in
        # the embedded path; standalone must import it explicitly and pin the
        # same package (niri-unstable) so its config schema matches the binary.
        inputs.niri.homeModules.niri
        ({pkgs, ...}: {programs.niri.package = lib.mkDefault pkgs.niri-unstable;})
        {
          fireproof = resolvedFacts;
          home = {inherit username homeDirectory stateVersion;};
        }
      ]
      ++ extraModules;
  }
