{hostname, ...}: {
  imports = [
    ../../modules/base.nix
    ../../modules/shell.nix
    ../../modules/graphical.nix
  ];

  config = {
    user.username = "nickolaj";
    system.stateVersion = "24.11";
  };
}
