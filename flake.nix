{
  description = "Your new nix config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    astal = {
      url = "github:aylur/astal";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ags = {
      url = "github:aylur/ags";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    nixpkgs-unstable,
    nixos-generators,
    home-manager,
    ...
  } @ inputs: let
    system = "x86_64-linux";
    stateVersion = "24.11";
    pkgs = nixpkgs.legacyPackages.${system};
    mkSystem = username: machine:
      nixpkgs.lib.nixosSystem {
        system = system;
        specialArgs = {inherit inputs username machine stateVersion;};
        modules = [
          (import (./machines + "/${machine}"))
          home-manager.nixosModules.home-manager
          nixos-generators.nixosModules.all-formats
        ];
      };
  in {
    # Available through 'nixos-rebuild --flake .#wsl'
    formatter.${system} = pkgs.alejandra;
    nixosConfigurations = {
      desktop = mkSystem "nickolaj" "desktop";
      qemu = mkSystem "nickolaj" "qemu";
    };
  };
}
