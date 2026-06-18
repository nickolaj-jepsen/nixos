{
  flake.modules.homeManager.niri-binds = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      programs.niri.settings.binds = {
        "XF86AudioRaiseVolume" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "audio" "increment" "3"];
        };
        "XF86AudioLowerVolume" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "audio" "decrement" "3"];
        };
        "XF86AudioMute" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "audio" "mute"];
        };
        "XF86AudioMicMute" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "audio" "micmute"];
        };
        "XF86MonBrightnessUp" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "brightness" "increment" "5" ""];
        };
        "XF86MonBrightnessDown" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "brightness" "decrement" "5" ""];
        };
        "XF86AudioPlay" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "mpris" "playPause"];
        };
        "XF86AudioPause" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "mpris" "playPause"];
        };
        "XF86AudioNext" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "mpris" "next"];
        };
        "XF86AudioPrev" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "mpris" "previous"];
        };
        "XF86AudioStop" = {
          allow-when-locked = true;
          action.spawn = ["dms" "ipc" "mpris" "stop"];
        };
        "Mod+N" = {
          action.spawn = ["dms" "ipc" "notifications" "toggle"];
          hotkey-overlay.title = "Toggle Notification Center";
        };
        "Mod+V" = {
          action.spawn = ["dms" "ipc" "clipboard" "toggle"];
          hotkey-overlay.title = "Toggle Clipboard Manager";
        };
        "Mod+Space" = {
          action.spawn = ["dms" "ipc" "spotlight" "toggle"];
          hotkey-overlay.title = "Toggle Application Launcher";
        };
        "Mod+Semicolon" = {
          action.spawn = ["dms" "ipc" "spotlight" "toggleQuery" ":"];
          hotkey-overlay.title = "Toggle Emoji Picker";
        };
        "Mod+P" = {
          action.spawn = ["dms" "ipc" "powermenu" "toggle"];
          hotkey-overlay.title = "Toggle Power Menu";
        };
        # Mod+D / Mod+Ctrl+D / Mod+Shift+D are taken by niri-dynamic-workspaces.
        "Mod+B" = {
          action.spawn = ["dms" "ipc" "dash" "toggle" ""];
          hotkey-overlay.title = "Toggle Dashboard";
        };
        "Mod+Shift+N" = {
          action.spawn = ["dms" "ipc" "notepad" "toggle"];
          hotkey-overlay.title = "Toggle Notepad";
        };
        "Mod+Shift+Comma" = {
          action.spawn = ["dms" "ipc" "settings" "focusOrToggle"];
          hotkey-overlay.title = "Toggle DMS Settings";
        };
        "Mod+Shift+Escape" = {
          action.spawn = ["dms" "ipc" "processlist" "focusOrToggle"];
          hotkey-overlay.title = "Toggle Process List";
        };
        "Mod+Shift+I" = {
          action.spawn = ["dms" "ipc" "inhibit" "toggle"];
          hotkey-overlay.title = "Toggle Keep-Awake (Idle Inhibit)";
        };
        "Mod+Alt+L" = {
          action.spawn = ["dms" "ipc" "lock" "lock"];
          hotkey-overlay.title = "Lock Screen";
        };
        "Mod+Shift+B" = {
          action.spawn = ["dms" "ipc" "night" "toggle"];
          hotkey-overlay.title = "Toggle Night Mode (warm tint)";
        };
        "Mod+Ctrl+N" = {
          action.spawn = ["dms" "ipc" "notifications" "toggleDoNotDisturb"];
          hotkey-overlay.title = "Toggle Do Not Disturb";
        };
        "Mod+Shift+P" = {
          action.spawn = ["dms" "ipc" "color-picker" "toggle"];
          hotkey-overlay.title = "Toggle Color Picker";
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
        "Mod+M".action.toggle-column-tabbed-display = {};
        "Mod+A".action.toggle-overview = {};
        "Mod+S".action.toggle-window-floating = {};
        "Mod+C".action.switch-preset-column-width = {};

        "Mod+Z".action.set-column-width = "-5%";
        "Mod+X".action.set-column-width = "+5%";
        "Mod+Ctrl+X".action.expand-column-to-available-width = {};
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

        "Mod+q".action.focus-workspace = "01";
        "Mod+w".action.focus-workspace = "02";
        "Mod+e".action.focus-workspace = "03";
        "Mod+r".action.focus-workspace = "04";
        "Mod+t".action.focus-workspace = "05";
        "Mod+Shift+q".action.move-column-to-workspace = "01";
        "Mod+Shift+w".action.move-column-to-workspace = "02";
        "Mod+Shift+e".action.move-column-to-workspace = "03";
        "Mod+Shift+r".action.move-column-to-workspace = "04";
        "Mod+Shift+t".action.move-column-to-workspace = "05";

        "Mod+Comma".action.consume-or-expel-window-left = {};
        "Mod+Period".action.consume-or-expel-window-right = {};

        # Mod+Print: region grab annotated in satty (the packaged screenshot
        # script). Built-in Print/Ctrl/Alt+Print stay for quick no-annotate grabs.
        "Mod+Print" = {
          action.spawn = ["screenshot"];
          hotkey-overlay.title = "Screenshot region (annotate in satty)";
        };
        "Print".action.screenshot = {};
        "Ctrl+Print".action.screenshot-screen = {};
        "Alt+Print".action.screenshot-window = {};

        "Mod+Slash".action.show-hotkey-overlay = {};

        "Mod+Return".action.spawn = ["ghostty"];
        "Mod+Backspace".action.close-window = {};
      };
    };
  };
}
