{
  username,
  pkgs,
  ...
}: {
  environment.systemPackages = [
    pkgs.docker
    pkgs.docker-compose
  ];

  virtualisation.docker.enable = true;
  virtualisation.docker.storageDriver = "btrfs";
  users.extraGroups.docker.members = [username];
}
