# Enabled when: always
{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
in {
  environment.systemPackages = [
    pkgs.docker
    pkgs.docker-compose
  ];

  virtualisation.docker = {
    enable = true;
    enableOnBoot = lib.mkDefault false;
    storageDriver = "btrfs";
  };
  virtualisation.oci-containers = {
    backend = "docker";
  };

  users.extraGroups.docker.members = [username];
}
