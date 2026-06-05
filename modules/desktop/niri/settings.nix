{
  config,
  lib,
  pkgs,
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
        path = lib.getExe pkgs.xwayland-satellite-unstable;
      };
      environment = {
        # niri already defaults GTK apps to the Wayland backend; forcing
        # GDK_BACKEND globally can mis-init xdg-desktop-portal-gnome (itself a
        # GTK process) and cause flaky screencasts. See niri "Important Software".
        NIXOS_OZONE_WL = "1";
      };
      # Skip the per-session "Important Hotkeys" popup, and make Mod+Slash show
      # only the binds defined here (not niri's built-in defaults).
      hotkey-overlay = {
        skip-at-startup = true;
        hide-not-bound = true;
      };
      # Make niri the source of truth for the cursor so XWayland/Qt children
      # inherit it too (matches the Adwaita/24px choice in gtk.nix).
      cursor = {
        theme = "Adwaita";
        size = 24;
      };
      # Modest global slowdown + crisp window open/close; niri's signature
      # view-movement spring is left at its default.
      animations = {
        slowdown = 0.8;
        window-open.kind.easing = {
          duration-ms = 150;
          curve = "ease-out-quad";
        };
        window-close.kind.easing = {
          duration-ms = 150;
          curve = "ease-out-quad";
        };
      };
      # Theme the overview (opened constantly via Mod+A) to the Flexoki bg and
      # zoom out a touch so the 3-monitor bird's-eye fits comfortably.
      overview = {
        backdrop-color = "#${c.bg}";
        zoom = 0.45;
      };
      # Built-in Print/Ctrl+Print/Alt+Print only copy to the clipboard; the
      # satty script (Mod+Print) owns the save-to-disk path. Avoids a growing
      # ~/Pictures/Screenshots folder of captures you never asked to keep.
      screenshot-path = null;
      layout = {
        gaps = 10;
        focus-ring.enable = false;
        insert-hint.display.color = "#${c.accent}";
        preset-column-widths = [
          {proportion = 0.33333;}
          {proportion = 0.5;}
          {proportion = 0.66667;}
          {proportion = 1.0;}
        ];
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
          # Match the active border accent; flag attention-seeking tabs in red.
          active.color = "#${c.accent}";
          urgent.color = "#${c.red}";
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
      debug.honor-xdg-activation-with-invalid-serial = true;
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
        {
          matches = [{app-id = "^net-runelite-client-RuneLite$";}];
          open-floating = true;
        }
        # Floating windows (Mod+S) get a soft drop shadow so the state reads at
        # a glance against the otherwise flat Flexoki theme.
        {
          matches = [{is-floating = true;}];
          shadow = {
            enable = true;
            softness = 30;
            spread = 5;
            offset = {
              x = 0;
              y = 5;
            };
            color = "#100F0F99";
          };
        }
      ];
    };
  };
}
