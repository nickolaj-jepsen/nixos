{
  inputs,
  withSystem,
  lib,
  ...
}:
with lib; let
  mkSystemImports = hostname: let
    hostDirectory = ./. + ("/" + hostname);
    nixFiles = filter (file: hasSuffix ".nix" file) (attrNames (builtins.readDir hostDirectory));
    imports = map (file: ./. + ("/" + hostname + "/" + file)) nixFiles;
  in {
    inherit imports;
  };

  mkSystem = {
    hostname,
    username,
    modules ? [],
    system ? "x86_64-linux",
  }:
    withSystem system (
      {system, ...}: let
        pkgs = import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        pkgsUnstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {inherit inputs hostname username pkgs pkgsUnstable;};
          modules =
            [
              inputs.disko.nixosModules.disko
              inputs.nixos-generators.nixosModules.all-formats
              inputs.home-manager.nixosModules.home-manager
              inputs.agenix.nixosModules.default
              inputs.agenix-rekey.nixosModules.default
              inputs.nix-index-database.nixosModules.nix-index
              inputs.nixos-facter-modules.nixosModules.facter
              ../modules/base/user.nix
              (mkSystemImports hostname)
            ]
            ++ modules
            ++ (
              lib.optional (builtins.pathExists ./${hostname}/facter.json)
              {config.facter.reportPath = ./${hostname}/facter.json;}
            );
        }
    );
in {
  config.flake.nixosConfigurations = {
    laptop = mkSystem {
      hostname = "laptop";
      username = "nickolaj";
      modules = [
        ../modules/required.nix
        ../modules/shell.nix
        ../modules/graphical.nix
        ../modules/devenv.nix
      ];
    };
    desktop = mkSystem {
      hostname = "desktop";
      username = "nickolaj";
      modules = [
        ../modules/required.nix
        ../modules/shell.nix
        ../modules/graphical.nix
        ../modules/devenv.nix
      ];
    };
  };
}
