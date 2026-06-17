{
  inputs,
  withSystem,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  fpLib = import ../lib {inherit lib;};

  # The shared module tree, collected at the flake level as
  # flake.modules.nixos.<name> (see flake.nix) and splatted into every host —
  # replaces the former per-host `(inputs.import-tree ../modules)`.
  sharedNixosModules = builtins.attrValues config.flake.modules.nixos;

  mkSystem = {
    host,
    modules ? [],
    system ? "x86_64-linux",
  }:
    withSystem system (
      {system, ...}:
        inputs.nixpkgs.lib.nixosSystem {
          specialArgs = {inherit inputs fpLib;};
          modules =
            [
              {nixpkgs.hostPlatform = system;}
              inputs.disko.nixosModules.disko
              inputs.nixos-generators.nixosModules.all-formats
              inputs.home-manager.nixosModules.home-manager
              inputs.agenix.nixosModules.default
              inputs.agenix-rekey.nixosModules.default
              inputs.nix-index-database.nixosModules.nix-index
              inputs.nixos-facter-modules.nixosModules.facter
              inputs.dank-material-shell.nixosModules.dank-material-shell
              inputs.niri.nixosModules.niri
              inputs.nixos-wsl.nixosModules.default
              inputs.self.nixosModules.overlays
            ]
            ++ sharedNixosModules
            # The host's own directory (its default.nix and sibling files).
            # `_`-prefixed helper files are skipped (see import-tree).
            ++ [(inputs.import-tree host)]
            ++ modules;
        }
    );

  targets = {
    laptop = ./laptop;
    desktop = ./desktop;
    work = ./work;
    homelab = ./homelab;
    desktop-wsl = ./desktop-wsl;
    minilab = ./minilab;
  };

  mkBootstrap = name:
    mkSystem {
      host = ./bootstrap;
      modules = [
        ./bootstrap/_bake.nix
        {fireproof.bootstrap.targetHost = name;}
      ];
    };
in {
  config.flake.nixosConfigurations =
    (lib.mapAttrs (_: host: mkSystem {inherit host;}) targets)
    // {
      bootstrap = mkSystem {host = ./bootstrap;};
    }
    // (lib.mapAttrs' (name: _: lib.nameValuePair "bootstrap-${name}" (mkBootstrap name)) targets);
}
