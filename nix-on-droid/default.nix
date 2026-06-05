# Proof-of-concept nix-on-droid (Nix on Android) integration.
#
# Unlike `hosts/`, these are NOT NixOS systems. nix-on-droid runs the Nix
# package manager + home-manager in an Android userspace (Termux-like, via
# proot) — there is no systemd and no NixOS module layer, so the `fireproof.*`
# modules in `modules/` cannot be imported here. Each device config is therefore
# self-contained. See ./README.md for setup and the secrets workflow.
#
# We build directly against `nixpkgs.legacyPackages.aarch64-linux` rather than
# going through flake-parts' `withSystem`, so we don't have to add
# `aarch64-linux` to the top-level `systems` (which would needlessly expand
# every perSystem output — devShells, formatter, docs — to aarch64).
{inputs, ...}: let
  inherit (inputs.nixpkgs) lib;
  fpLib = import ../lib {inherit lib;};

  system = "aarch64-linux";

  mkDroid = host:
    inputs.nix-on-droid.lib.nixOnDroidConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      home-manager-path = inputs.home-manager.outPath;
      extraSpecialArgs = {inherit inputs fpLib;};
      modules = [host];
    };
in {
  config.flake.nixOnDroidConfigurations = {
    phone = mkDroid ./phone;
  };
}
