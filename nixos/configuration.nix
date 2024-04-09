{
  inputs,
  outputs,
  username,
  hostname,
  pkgs,
  lib,
  ...
}: {
  imports = [
    inputs.home-manager.nixosModules.home-manager
  ];

  nixpkgs = {
    config = {
      allowUnfree = true;
    };
    hostPlatform = lib.mkDefault "x86_64-linux";
  };

  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
	substituters = ["https://hyprland.cachix.org"];
	trusted-public-keys = ["hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="];
  };

  home-manager = {
    extraSpecialArgs = { inherit inputs outputs username hostname; };
    users.${username}.imports = [
      ../home-manager/default.nix
    ];
  };

  networking.hostName = hostname;

  environment.systemPackages = with pkgs; [
    wget
    fish
  ];
  
  programs.fish.enable = true;

  users.users = {
    ${username} = {
      initialPassword = "fireproof";
      isNormalUser = true;
      extraGroups = ["wheel"];
    };
  };

  security.sudo.wheelNeedsPassword = false;
  system.stateVersion = "23.11";
}
