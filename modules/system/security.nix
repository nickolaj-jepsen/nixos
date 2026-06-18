{
  flake.modules.nixos.security = _: {
    security.sudo.wheelNeedsPassword = false;
    services.gnome.gnome-keyring.enable = true;
  };
}
