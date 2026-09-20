{
  flake.modules.nixos.security = {
    config,
    lib,
    ...
  }: {
    security.sudo.wheelNeedsPassword = false;
    # Only a graphical login unlocks it.
    services.gnome.gnome-keyring.enable = lib.mkIf config.fireproof.desktop.enable true;
  };
}
