{
  inputs,
  withSystem,
  ...
}: let
  mkSystem = {
    host,
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
          specialArgs = {inherit inputs pkgsUnstable;};
          modules =
            [
              inputs.disko.nixosModules.disko
              inputs.nixos-generators.nixosModules.all-formats
              inputs.home-manager.nixosModules.home-manager
              inputs.agenix.nixosModules.default
              inputs.agenix-rekey.nixosModules.default
              inputs.nix-index-database.nixosModules.nix-index
              inputs.nixos-facter-modules.nixosModules.facter
              inputs.dank-material-shell.nixosModules.dank-material-shell
              inputs.niri.nixosModules.niri
              inputs.determinate.nixosModules.default
              inputs.nixos-wsl.nixosModules.default
              ../modules/base
              ../modules/system
              ../modules/programs
              ../modules/desktop
              ../modules/homelab
              ../modules/scripts
              host
            ]
            ++ modules;
        }
    );
in {
  config.flake.nixosConfigurations = {
    laptop = mkSystem {host = ./laptop;};
    desktop = mkSystem {host = ./desktop;};
    work = mkSystem {host = ./work;};
    homelab = mkSystem {host = ./homelab;};
    bootstrap = mkSystem {host = ./bootstrap;};
    desktop-wsl = mkSystem {host = ./desktop-wsl;};
    minilab = mkSystem {host = ./minilab;};
  };
}
