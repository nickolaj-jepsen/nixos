{inputs, ...}: {
  flake.modules.nixos.niri = {
    config,
    lib,
    pkgs,
    ...
  }: {
    imports = [inputs.niri.nixosModules.niri];
    config = lib.mkMerge [
      # Built against our nixpkgs, niri never hits niri.cachix.org (attic serves it).
      {niri-flake.cache.enable = false;}

      (lib.mkIf config.fireproof.desktop.enable {
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
      })
    ];
  };
}
