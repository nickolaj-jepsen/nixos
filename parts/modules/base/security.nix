{config, ...}: {
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [
    "root"
    config.user.username
  ];
}
