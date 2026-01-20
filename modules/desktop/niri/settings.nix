{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  c = config.fireproof.theme.colors;
in {
  config = lib.mkIf config.fireproof.desktop.windowManager.enable {
    fireproof.home-manager.programs.niri.settings = {
      prefer-no-csd = true;
      clipboard.disable-primary = true;
      spawn-at-startup = [
        {command = ["systemctl" "--user" "start" "hyprpaper"];}
      ];
      xwayland-satellite = {
        enable = true;
        path = lib.getExe inputs.niri.packages."${pkgs.stdenv.hostPlatform.system}".xwayland-satellite-unstable;
      };
      environment = {
        NIXOS_OZONE_WL = "1";
        GDK_BACKEND = "wayland";
      };
      layout = {
        gaps = 10;
        focus-ring.enable = false;
        insert-hint.display.color = "#${c.accent}";
        border = {
          enable = true;
          width = 2;
          active.color = "#${c.accent}";
          inactive.color = "#${c.ui}";
        };
        tab-indicator = {
          hide-when-single-tab = true;
          place-within-column = true;
          gap = 2;
          position = "top";
          corner-radius = 8;
        };
      };
      input = {
        focus-follows-mouse = {
          enable = true;
          max-scroll-amount = "0%";
        };
        mouse.accel-profile = "flat";
        keyboard.xkb.layout = "eu";
      };
      window-rules = [
        {
          clip-to-geometry = true;
          geometry-corner-radius = {
            top-left = 8.0;
            top-right = 8.0;
            bottom-left = 8.0;
            bottom-right = 8.0;
          };
        }
      ];
    };
  };
}
