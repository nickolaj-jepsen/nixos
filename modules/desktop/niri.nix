{pkgsUnstable, ...}: {
  # TODO: Move these to a separate module
  fireproof.home-manager.programs.waybar = {
    enable = true;
    systemd.enable = true;
    systemd.target = "niri.target";
    settings = {
      bar = {
        layer = "top";
        position = "top";
        modules-left = ["clock" "niri/workspaces"];
        modules-center = ["niri/window"];
        modules-right = ["backlight" "battery" "pulseaudio" "tray"];

        pulseaudio = {
          format = "{volume}% {icon}";
          format-muted = "󰝟 ";
          format-icons = {
            default = ["󰕿 " "󰖀 " "󰕾 "];
            headphone = "󰋋 ";
          };
          on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        };
      };
    };
    style = ''
      * {
        font-family: Hack Nerd Font Mono;
        font-size: 14px;
      }
      window#waybar, #clock, #pulseaudio, #battery, #backlight, #tray {
        background: #1C1B1A;
        color: #DAD8CE;
        border-bottom: 2px solid #CF6A4C;
      }
          
      #workspaces button.focused {
        background: #CF6A4C;
        color: #1C1B1A;
        box-shadow: 0 0 0 #CF6A4C;
      }

      /* Default */
      button {
        /* Use box-shadow instead of border so the text isn't offset */
        box-shadow: inset 0 -3px transparent;
        /* Avoid rounded borders under each button name */
        border: none;
        border-radius: 0;
      }

      /* https://github.com/Alexays/Waybar/wiki/FAQ#the-workspace-buttons-have-a-strange-hover-effect */
      button:hover {
        background: inherit;
        box-shadow: inset 0 -3px #ffffff;
      }

      /* you can set a style on hover for any module like this */
      #pulseaudio:hover {
        background-color: #a37800;
      }

      #workspaces button {
        padding: 0 5px;
        background-color: transparent;
        color: #ffffff;
      }

      #workspaces button:hover {
        background: rgba(0, 0, 0, 0.2);
      }

      #workspaces button.urgent {
        background-color: #eb4d4b;
      }

      #window,
      #workspaces {
          margin: 0 4px;
      }


      #tray > .passive {
          -gtk-icon-effect: dim;
      }

      #tray > .needs-attention {
          -gtk-icon-effect: highlight;
          background-color: #eb4d4b;
      }
      #tray > .active {
          -gtk-icon-effect: highlight;
          background-color: #eb4d4b;
      }'';
  };

  programs.niri = {
    enable = true;
    package = pkgsUnstable.niri;
  };
  fireproof.home-manager.programs.niri.settings = {
    prefer-no-csd = true;
    spawn-at-startup = [
      {command = ["systemctl" "--user" "start" "hypridle"];}
      {command = ["systemctl" "--user" "start" "hyprpaper"];}
      {command = ["systemctl" "--user" "start" "mako"];}
      {command = ["systemctl" "--user" "start" "waybar"];}
    ];
    layout = {
      gaps = 10;
      focus-ring.enable = false;
      insert-hint.display.color = "#CF6A4C";
      border = {
        enable = true;
        width = 2;
        active.color = "#CF6A4C";
        inactive.color = "#343331";
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
      focus-follows-mouse.enable = true;
      mouse.accel-profile = "flat";
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
    binds = {
      "XF86AudioRaiseVolume" = {
        allow-when-locked = true;
        action.spawn = [
          "wpctl"
          "set-volume"
          "@DEFAULT_AUDIO_SINK@"
          "0.1+"
        ];
      };
      "XF86AudioLowerVolume" = {
        allow-when-locked = true;
        action.spawn = [
          "wpctl"
          "set-volume"
          "@DEFAULT_AUDIO_SINK@"
          "0.1-"
        ];
      };
      "XF86AudioMute" = {
        allow-when-locked = true;
        action.spawn = [
          "wpctl"
          "set-mute"
          "@DEFAULT_AUDIO_SINK@"
          "toggle"
        ];
      };
      "XF86AudioMicMute" = {
        allow-when-locked = true;
        action.spawn = [
          "wpctl"
          "set-mute"
          "@DEFAULT_AUDIO_SOURCE@"
          "toggle"
        ];
      };

      "Mod+Left".action.focus-column-or-monitor-left = {};
      "Mod+Down".action.focus-window-or-monitor-down = {};
      "Mod+Up".action.focus-window-or-monitor-up = {};
      "Mod+Right".action.focus-column-or-monitor-right = {};
      "Mod+H".action.focus-column-or-monitor-left = {};
      "Mod+J".action.focus-window-or-monitor-down = {};
      "Mod+K".action.focus-window-or-monitor-up = {};
      "Mod+L".action.focus-column-or-monitor-right = {};

      "Mod+Shift+Left".action.move-column-left-or-to-monitor-left = {};
      "Mod+Shift+Down".action.move-window-down = {};
      "Mod+Shift+Up".action.move-window-up = {};
      "Mod+Shift+Right".action.move-column-right-or-to-monitor-right = {};
      "Mod+Shift+H".action.move-column-left-or-to-monitor-left = {};
      "Mod+Shift+J".action.move-window-down = {};
      "Mod+Shift+K".action.move-window-up = {};
      "Mod+Shift+L".action.move-column-right-or-to-monitor-right = {};

      "Mod+Home".action.focus-column-first = {};
      "Mod+End".action.focus-column-last = {};
      "Mod+Shift+Home".action.move-column-to-first = {};
      "Mod+Shift+End".action.move-column-to-last = {};

      "Mod+Ctrl+Left".action.focus-monitor-left = {};
      "Mod+Ctrl+Down".action.focus-monitor-down = {};
      "Mod+Ctrl+Up".action.focus-monitor-up = {};
      "Mod+Ctrl+Right".action.focus-monitor-right = {};
      "Mod+Ctrl+H".action.focus-monitor-left = {};
      "Mod+Ctrl+J".action.focus-monitor-down = {};
      "Mod+Ctrl+K".action.focus-monitor-up = {};
      "Mod+Ctrl+L".action.focus-monitor-right = {};

      "Mod+F".action.maximize-column = {};
      "Mod+Shift+F".action.fullscreen-window = {};
      "Mod+A".action.toggle-column-tabbed-display = {};
      "Mod+C".action.center-column = {};
      "Mod+S".action.toggle-window-floating = {};

      "Mod+Z".action.set-column-width = "-5%";
      "Mod+X".action.set-column-width = "+5%";
      "Mod+Shift+Z".action.set-window-height = "-5%";
      "Mod+Shift+X".action.set-window-height = "+5%";

      "Mod+Shift+WheelScrollDown".action.focus-workspace-down = {};
      "Mod+Shift+WheelScrollUp".action.focus-workspace-up = {};
      "Mod+WheelScrollDown".action.focus-column-right = {};
      "Mod+WheelScrollUp".action.focus-column-left = {};

      "Mod+WheelScrollRight".action.focus-column-right = {};
      "Mod+WheelScrollLeft".action.focus-column-left = {};
      "Mod+Shift+WheelScrollRight".action.move-column-right = {};
      "Mod+Shift+WheelScrollLeft".action.move-column-left = {};

      "Mod+q".action.focus-workspace = 1;
      "Mod+w".action.focus-workspace = 2;
      "Mod+e".action.focus-workspace = 3;
      "Mod+r".action.focus-workspace = 4;
      "Mod+t".action.focus-workspace = 5;
      "Mod+Shift+q".action.move-column-to-workspace = 1;
      "Mod+Shift+w".action.move-column-to-workspace = 2;
      "Mod+Shift+e".action.move-column-to-workspace = 3;
      "Mod+Shift+r".action.move-column-to-workspace = 4;
      "Mod+Shift+t".action.move-column-to-workspace = 5;

      "Mod+Comma".action.consume-or-expel-window-left = {};
      "Mod+Period".action.consume-or-expel-window-right = {};

      "Print".action.screenshot = {};
      "Ctrl+Print".action.screenshot-screen = {};
      "Alt+Print".action.screenshot-window = {};

      "Mod+Slash".action.show-hotkey-overlay = {};

      "Mod+Return".action.spawn = ["ghostty"];
      "Mod+Space".action.spawn = ["fuzzel"];
      "Mod+Backspace".action.close-window = {};
    };
  };
}
