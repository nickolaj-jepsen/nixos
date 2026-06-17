{
  flake.aspectTags.niri = ["windowManager"];
  flake.modules.nixos.niri = {
    pkgs,
    ...
  }: {
    config = {
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
