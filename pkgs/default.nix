# Own packages, nixpkgs by-name style: pkgs/<name>/package.nix is callPackage'd
# into pkgs.<name> on every host and exposed as packages.<system>.<name>, so
# `nix build .#<name>` builds one without evaluating a host.
{
  inputs,
  lib,
  ...
}: let
  names = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.));

  # The overlay stack, shared by the nixos/darwin overlay modules and by mkHome (so a
  # standalone home-manager build gets pkgs.unstable etc. too).
  overlayList = [
    inputs.nix-vscode-extensions.overlays.default
    inputs.obsidian-extensions.overlays.default
    inputs.firefox-addons.overlays.default
    inputs.niri.overlays.niri
    inputs.fnug.overlays.default
    inputs.self.overlays.default
  ];
in {
  flake.overlays.default = final: _prev: let
    # `inputs` in scope for packages built from a `flake = false` input.
    callPackage = final.newScope {inherit inputs;};
  in
    {
      # Inherits the host's nixpkgs.config, so allowUnfree & co. apply to unstable too.
      unstable = import inputs.nixpkgs-unstable {
        inherit (final.stdenv.hostPlatform) system;
        inherit (final) config;
      };
    }
    // lib.genAttrs names (name: callPackage ./${name}/package.nix {});

  flake.lib.overlays = overlayList;

  flake.nixosModules.overlays = _: {
    nixpkgs.overlays = overlayList;
  };

  flake.darwinModules.overlays = _: {
    nixpkgs.overlays = overlayList;
  };

  perSystem = {system, ...}: let
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = overlayList;
    };
  in {
    packages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (lib.genAttrs names (name: pkgs.${name}));
  };
}
