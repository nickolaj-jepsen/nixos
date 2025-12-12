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
        pkgsUnstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {inherit inputs hostname username pkgsUnstable;};
          modules =
            [
              inputs.disko.nixosModules.disko
              inputs.nixos-generators.nixosModules.all-formats
              inputs.home-manager.nixosModules.home-manager
              inputs.agenix.nixosModules.default
              inputs.agenix-rekey.nixosModules.default
              inputs.nix-index-database.nixosModules.nix-index
              inputs.nixos-facter-modules.nixosModules.facter
              inputs.dankMaterialShell.nixosModules.dankMaterialShell
              inputs.niri.nixosModules.niri
              ../modules/base
              ../modules/system
              ../modules/programs
              ../modules/desktop
              ../modules/homelab
              (mkSystemImports hostname)
              {nixpkgs.config.allowUnfree = true;}
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
    bootstrap = mkSystem {
      hostname = "bootstrap";
      username = "nixos";
    };

    laptop = mkSystem {
      hostname = "laptop";
      username = "nickolaj";
    };
    desktop = mkSystem {
      hostname = "desktop";
      username = "nickolaj";
    };
    work = mkSystem {
      hostname = "work";
      username = "nickolaj";
    };
    homelab = mkSystem {
      hostname = "homelab";
      username = "nickolaj";
    };
  };
}
