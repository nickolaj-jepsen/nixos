# Build a standalone home-manager configuration from ALL dendritic homeManager
# leaves — each self-gates with lib.mkIf config.fireproof.<feature>.enable, flipped
# by the host card's `shared` facts — the same leaves the embedded path uses, but
# with no NixOS eval (osConfig = null). Consumed by buildHome (hosts/default.nix)
# for class = "home" hosts; the dev-ao CI check builds the resulting
# homeConfigurations entry so a home-manager half that starts reading osConfig (or a
# non-shared option) fails `just check`, not just a future deploy.
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
        # niri's home-manager module is auto-shared by the niri NixOS module in
        # the embedded path; standalone must import it explicitly and pin the
        # same package (niri-unstable) so a home host that selects niri matches
        # the binary. Inert (programs.niri.enable defaults false) for a headless
        # home like dev-ao that never selects it.
        inputs.niri.homeModules.niri
        ({pkgs, ...}: {programs.niri.package = lib.mkDefault pkgs.niri-unstable;})
        ({config, ...}: {
          # Identity comes from the fireproof facts the host's `shared` card sets
          # (via extraModules), so a home host needs no pre-eval username arg.
          home.username = lib.mkDefault config.fireproof.username;
          home.homeDirectory = lib.mkDefault "/home/${config.fireproof.username}";
          home.stateVersion = lib.mkDefault "24.11";
        })
      ]
      ++ extraModules;
  }
