{
  description = "Your new nix config";

  nixConfig = {
    extra-substituters = [
      "https://hyprland.cachix.org"
      "https://walker.cachix.org"
    ];

    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "walker.cachix.org-1:fG8q+uAaMqhsMxWjwvk0IMb4mFPFLqHjuvfwQxE4oJM="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";

    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    astal.url = "github:aylur/astal";
    astal.inputs.nixpkgs.follows = "nixpkgs";
    ags.url = "github:aylur/ags";
    ags.inputs.nixpkgs.follows = "nixpkgs";

    walker.url = "github:abenz1267/walker";
    walker.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix-rekey.url = "github:oddlama/agenix-rekey";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena";
    colmena.inputs.nixpkgs.follows = "nixpkgs";

    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
  };

  outputs = {
    flake-parts,
    nixpkgs,
    ...
  } @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.agenix-rekey.flakeModule
        ./parts/devshell.nix
        ./parts/vm.nix
        ./parts/formatter.nix
        ./parts/hosts
      ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem = {
        pkgs,
        system,
        ...
      }: {
        # This sets `pkgs` to a nixpkgs with allowUnfree option set.
        _module.args.pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        _module.args.pkgsUnstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      };
    };
}
