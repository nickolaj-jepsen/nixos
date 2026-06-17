# Throwaway standalone home-manager configuration built in `just check`. It
# evaluates the dendritic homeManager leaves with no NixOS eval (osConfig =
# null), so it fails loudly if any home-manager half ever reads osConfig or a
# non-shared option. Exercises a broad aspect set to cover most leaves.
{
  config,
  inputs,
  lib,
  ...
}: let
  fpLib = import ./lib {inherit lib;};
  aspectsLib = import ./lib/aspects.nix {inherit lib;};
  mkHome = import ./lib/mkHome.nix {
    inherit inputs lib fpLib aspectsLib;
    inherit (config) flake;
  };
  homeCfg = mkHome {
    username = "check";
    aspects = ["workstation" "physical" "clickhouse" "chromium"];
  };
in {
  flake.homeConfigurations.portability-check = homeCfg;

  # Build it in `just check` (nix flake check) so a home-manager half that
  # starts reading osConfig fails CI, not just a future standalone host.
  perSystem = {system, ...}:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.portability-check = homeCfg.activationPackage;
    };
}
