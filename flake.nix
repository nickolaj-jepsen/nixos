{
  description = "Your new nix config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim/nixos-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

	hyprland.url = "github:hyprwm/Hyprland";
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    nixos-wsl,
    vscode-server,
    nixvim,
    ...
  } @ inputs: let
    inherit (self) outputs;
  in {
    # Available through 'nixos-rebuild --flake .#wsl'
    nixosConfigurations = {
      virtualbox = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs outputs;
          username = "nickolaj";
          hostname = "virtualbox";
        };
        modules = [
          nixos-wsl.nixosModules.wsl
          vscode-server.nixosModules.default
          ./nixos/configuration.nix
          ./machines/virtualbox/configuration.nix
        ];
      };
      wsl = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs outputs;
          username = "nickolaj";
          hostname = "wsl";
        };
        modules = [
          nixos-wsl.nixosModules.wsl
          vscode-server.nixosModules.default
          ./nixos/configuration.nix
          ./machines/wsl/configuration.nix
        ];
      };
      legion = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs outputs;
          username = "nickolaj";
          hostname = "legion";
        };
        modules = [
          nixos-wsl.nixosModules.wsl
          vscode-server.nixosModules.default
          ./nixos/configuration.nix
          ./machines/legion/configuration.nix
        ];
      };
    };
  };
}
