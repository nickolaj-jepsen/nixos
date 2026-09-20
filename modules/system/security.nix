{
  flake.modules.nixos.security = {
    config,
    lib,
    ...
  }: {
    security.sudo.wheelNeedsPassword = false;
    # Puts sudo CVEs out of reach of service users.
    security.sudo.execWheelOnly = true;
    # Only a graphical login unlocks it.
    services.gnome.gnome-keyring.enable = lib.mkIf config.fireproof.desktop.enable true;
  };
}
