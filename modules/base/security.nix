{username, ...}: {
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [
    "root"
    "@wheel"
    username
  ];
  services.gnome.gnome-keyring.enable = true;
}
