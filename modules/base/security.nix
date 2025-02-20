{username, ...}: {
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [
    "root"
    "@wheel"
    username
  ];
}
