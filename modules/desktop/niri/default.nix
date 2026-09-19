{
  flake.modules.nixos.niri = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      programs.xwayland.enable = true;

      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.xdg-desktop-portal-gnome
          pkgs.xdg-desktop-portal-gtk
        ];
        config.common = {
          default = ["gtk"];
          "org.freedesktop.impl.portal.ScreenCast" = "gnome";
          "org.freedesktop.impl.portal.Screenshot" = "gnome";
          # This file outranks niri's own niri-portals.conf, so restate its Secret mapping.
          "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
        };
        xdgOpenUsePortal = true;
      };

      programs.niri = {
        enable = true;
        package = pkgs.niri-unstable;
      };
    };
  };
}
