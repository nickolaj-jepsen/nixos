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

  system.stateVersion = "23.11";
}
