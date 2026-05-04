{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./settings.nix
    ./binds.nix
    ./outputs.nix
    ./dynamic-workspaces.nix
  ];

  config = lib.mkIf config.fireproof.desktop.windowManager.enable {
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
}
