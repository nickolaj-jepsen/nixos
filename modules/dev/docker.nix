{
  username,
  pkgs,
  lib,
  ...
}: {
  environment.systemPackages = [
    pkgs.docker
    pkgs.docker-compose
  ];

  virtualisation.docker = {
    enable = true;
    enableOnBoot = lib.mkDefault false;
    storageDriver = "btrfs";
  };

  users.extraGroups.docker.members = [username];
}
