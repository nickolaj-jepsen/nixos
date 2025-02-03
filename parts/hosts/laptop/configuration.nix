{...}: {
  imports = [
    ../../modules/base.nix
    ../../modules/shell.nix
    ../../modules/graphical.nix
  ];

  config = {
    user.username = "nickolaj";
    networking.hostName = "laptop";
    system.stateVersion = "24.11";
  };
}
