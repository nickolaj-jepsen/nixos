# niri/settings.nix, niri/outputs.nix and niri/binds.nix in umbriel's terms. umbriel takes much
# of its design from niri, so most keys map one to one; the rest are marked where they differ.
{
  inputs,
  fpLib,
  ...
}: {
  flake.modules.homeManager.umbriel-settings = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    color = hex: "#${hex}FF";
    package = inputs.umbriel.packages.${pkgs.stdenv.hostPlatform.system}.default;
    primary = fpLib.primaryMonitorName config.fireproof.monitors;

    toml = (pkgs.formats.toml {}).generate "umbriel-config.toml" config.programs.umbriel.settings;
    # The HM module dropped build-time checks; unknown keys and bad binds only warn at runtime.
    validated = pkgs.runCommand "umbriel-config.toml" {} ''
      cp ${toml} $out
      # An unset NDW_UMBRIEL_INCLUDE fails the include even though it is optional; the service sets it.
      : > workspaces.toml
      NDW_UMBRIEL_INCLUDE=$PWD/workspaces.toml ${lib.getExe' package "umbriel"} config validate -c $out
    '';

    scratchFile = "${config.xdg.dataHome}/scratch/scratch.md";
    smerge = lib.getExe' pkgs.unstable.sublime-merge "smerge";
    openScratch = lib.getExe (pkgs.writeShellScriptBin "umbriel-scratch" (lib.replaceStrings
      ["@scratchDir@" "@scratchFile@"]
      [(lib.escapeShellArg (dirOf scratchFile)) (lib.escapeShellArg scratchFile)]
      (builtins.readFile ./scripts/open-scratch.sh)));

    workspaceKitty = lib.getExe (pkgs.writeShellApplication {
      name = "umbriel-workspace-kitty";
      runtimeInputs = [package pkgs.jq config.programs.kitty.package pkgs.coreutils config.programs.niri-dynamic-workspaces.package];
      text = builtins.readFile ./scripts/workspace-kitty.sh;
    });

    output = m:
      if !m.enable
      then {enabled = false;}
      else
        {
          position = [m.position.x m.position.y];
          inherit (m) scale;
          transform =
            if m.transform == null || m.transform == 0
            then "normal"
            else toString (m.transform * 90);
          focus_at_startup = m.name == primary;
        }
        // lib.optionalAttrs (m.resolution.width != null && m.resolution.height != null) {
          mode =
            "${toString m.resolution.width}x${toString m.resolution.height}"
            + lib.optionalString (m.refreshRateNiri != null) "@${toString m.refreshRateNiri}";
        };

    workspaceKeys = ["q" "w" "e" "r" "t"];
    # niri's named workspaces "01".."05"; a bare 01 would mean position 1.
    workspaceBinds = lib.listToAttrs (lib.concatLists (lib.imap1 (n: key: let
        name = "0${toString n}";
      in [
        (lib.nameValuePair "Mod+${lib.toUpper key}" "workspace-switch --name ${name}")
        (lib.nameValuePair "Mod+Shift+${lib.toUpper key}" "column-move-to-workspace --name ${name}")
      ])
      workspaceKeys));

    locked = action: {
      inherit action;
      allow_when_locked = true;
    };
  in {
    imports = [inputs.umbriel.homeModules.default];

    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.umbriel.enable && pkgs.stdenv.isLinux) {
      programs.umbriel = {
        enable = true;
        package = null;

        settings = {
          include.optional.files = ["$NDW_UMBRIEL_INCLUDE"];

          general = {
            show_cheatsheet = false;
            focus_on_activate = true;
          };

          environment.NIXOS_OZONE_WL = "1";

          output =
            lib.listToAttrs (map (m: lib.nameValuePair m.name (output m))
              (lib.filter (m: m.name != null) config.fireproof.monitors));

          # Named workspaces stay while empty; the rest are niri-style dynamic, stacked vertically.
          workspace = map (name: {inherit name;} // lib.optionalAttrs (primary != "") {output = primary;}) ["01" "02" "03" "04" "05"];

          layout = {
            gap = 10;
            extent_presets = [0.33333 0.5 0.66667 1.0];
            scrolling = {
              center_focused = "never";
              center_underfull_strip = false;
            };
          };

          appearance = {
            border_width = 2;
            # The outer frame: content clips to r²/(r+border) = 8, niri's window radius.
            corner_radius = 10;
            prefer_no_csd = true;
            # Turned on for floating windows only, below. niri's spread 5 has no equivalent.
            shadow = {
              enabled = false;
              softness = 30;
              offset_x = 0;
              offset_y = 5;
            };
            tab_bar = {
              tab_gap = 6;
              gap = 6;
            };
          };

          colors = {
            background = color c.bg;
            text_primary = color c.fg;
            text_muted = color c.muted;
            accent_primary = color c.accent;
            accent_secondary = color c.cyan;
            warning = color c.orange;
            error = color c.red;
            border = {
              focused = color c.accent;
              unfocused = color c.ui;
            };
            insert_hint = "#${c.accent}80";
            shadow = "#100F0F99";
            backdrop = color c.bg;
            tab_bar = {
              background = color c.bgAlt;
              text = color c.fgAlt;
              active = color c.accent;
              active_text = color c.black;
              active_unfocused = color c.accentContainer;
              active_unfocused_text = color c.whiteAlt;
              urgent = color c.red;
              urgent_text = color c.black;
            };
            overview = {
              background_tint = "#${c.black}80";
              badge = color c.accent;
            };
          };

          overview.background_blur = true;
          # niri's default hot corner, without a delay. umbriel's zone is 8 px, niri's 1 px.
          hot_corners.top_left = {
            enabled = true;
            delay_ms = 0;
            action = "overview-toggle";
          };

          animation = {
            workspaces.curve = "spring:1,1562.5";
            windows_move.curve = "spring:1,1250";
            windows_resize.curve = "spring:1,1250";
            overview = {
              curve = "spring:1,1250";
              workspace_curve = "spring:1,1562.5";
            };
            windows_in = {
              curve = "easeoutquad";
              duration_ms = 120;
            };
            windows_out = {
              curve = "easeoutquad";
              duration_ms = 120;
            };
            # niri switches border colours instantly.
            border.enabled = false;
          };

          input = {
            # niri's clipboard disable-primary.
            middle_click_paste = false;
            keyboard = {
              layout = "eu";
              repeat_delay = 600;
              repeat_rate = 25;
              track_layout = "global";
            };
            mouse.accel_profile = "flat";
            touchpad = {
              tap = true;
              natural_scroll = true;
              disable_while_typing = false;
            };
            # niri's focus-follows-mouse max-scroll-amount 0%: hover never scrolls the strip, and
            # floating windows focus without raising.
            focus = {
              follows_mouse = "sloppy";
              follows_mouse_max_scroll = 0.0;
              hover_raises = false;
            };
            cursor = {
              theme = "Adwaita";
              size = 24;
              follows_focus = false;
            };
          };

          # zed-scratch's note (Mod+N): umbriel's named scratchpads launch and float it natively.
          scratchpad = lib.optionals config.fireproof.dev.enable [
            {
              name = "zed";
              spawn_when_empty = openScratch;
              hide_when_empty = true;
            }
            {
              name = "sublime-merge";
              # A normal launch restores Merge's saved session instead of forcing a blank window.
              spawn_when_empty = smerge;
              hide_when_empty = true;
            }
          ];

          window_rule =
            [
              {
                match.app_id = "^kitty$";
                blur = true;
                # A background command's completion bell shouldn't steal focus.
                focus_on_activate = false;
              }
              {
                match.is_floating = true;
                shadow = true;
              }
              {
                match.app_id = "^dev\\.zed\\.Zed$";
                match.title = "^(?:(?!—).)+\\.(md|markdown)$";
                default_scrolling_extent_px = 864;
              }
              {
                match.app_id = "^org\\.gnome\\.NautilusPreviewer$";
                default_floating = true;
              }
              {
                match.app_id = ["^steam_app_" "^gamescope$" "^mpv$"];
                vrr = "always";
              }
            ]
            ++ lib.optionals config.fireproof.dev.enable [
              {
                match.app_id = "^dev\\.zed\\.Zed$";
                match.title = "^scratch\\.md";
                default_scratchpad = "zed";
                default_floating_size_px.width = 864;
                default_floating_size.height = 0.6;
                default_focused = true;
              }
              {
                match.app_id = "^sublime_merge$";
                default_scratchpad = "sublime-merge";
                default_floating_size = {
                  width = 0.9;
                  height = 0.85;
                };
                default_focused = true;
              }
            ];

          layer_rule = [
            {
              match.namespace = "^dms:";
              blur = true;
              blur_optimized = false;
              blur_ignore_alpha = 0.8 * (config.programs.dank-material-shell.settings.popupTransparency or 1.0);
            }
          ];

          # Any loaded config starts with no binds; Mod+drag move/resize stay built in.
          keybinds =
            {
              "XF86AudioRaiseVolume" = locked "spawn dms ipc audio increment 3";
              "XF86AudioLowerVolume" = locked "spawn dms ipc audio decrement 3";
              "XF86AudioMute" = locked "spawn dms ipc audio mute";
              "XF86AudioMicMute" = locked "spawn dms ipc audio micmute";
              "XF86MonBrightnessUp" = locked "spawn dms ipc brightness increment 5 \"\"";
              "XF86MonBrightnessDown" = locked "spawn dms ipc brightness decrement 5 \"\"";
              "XF86AudioPlay" = locked "spawn dms ipc mpris playPause";
              "XF86AudioPause" = locked "spawn dms ipc mpris playPause";
              "XF86AudioNext" = locked "spawn dms ipc mpris next";
              "XF86AudioPrev" = locked "spawn dms ipc mpris previous";
              "XF86AudioStop" = locked "spawn dms ipc mpris stop";

              "Mod+N" =
                if config.fireproof.dev.enable
                then "scratchpad-toggle zed"
                else "spawn dms ipc notepad toggle";
              "Mod+Shift+N" = "spawn dms ipc notifications toggle";
              "Mod+V" = "spawn dms ipc clipboard toggle";
              "Mod+Space" = "spawn dms ipc spotlight toggle";
              "Mod+Semicolon" = "spawn dms ipc spotlight toggleQuery :";
              "Mod+P" = "spawn dms ipc powermenu toggle";
              "Mod+B" =
                if config.fireproof.dev.agent-hub.enable
                then "spawn dms ipc widget toggle agentHub"
                else "spawn dms ipc dash toggle \"\"";
              # Mod+Shift+B / Mod+Ctrl+B (agent-hub) read niri's IPC.
              "Mod+Shift+Comma" = "spawn dms ipc settings focusOrToggle";
              "Mod+Shift+Escape" = "spawn dms ipc processlist focusOrToggle";
              "Mod+Shift+I" = "spawn dms ipc inhibit toggle";
              "Mod+Alt+L" = "spawn dms ipc lock lock";
              "Mod+Ctrl+N" = "spawn dms ipc notifications toggleDoNotDisturb";
              "Mod+Shift+P" = "spawn dms ipc color-picker toggle";

              "Mod+Left" = "window-focus-or-output-left";
              "Mod+Down" = "window-focus-or-output-down";
              "Mod+Up" = "window-focus-or-output-up";
              "Mod+Right" = "window-focus-or-output-right";
              "Mod+H" = "window-focus-or-output-left";
              "Mod+J" = "window-focus-or-output-down";
              "Mod+K" = "window-focus-or-output-up";
              "Mod+L" = "window-focus-or-output-right";

              "Mod+Shift+Left" = "window-move-or-output-left";
              "Mod+Shift+Down" = "window-move-down";
              "Mod+Shift+Up" = "window-move-up";
              "Mod+Shift+Right" = "window-move-or-output-right";
              "Mod+Shift+H" = "window-move-or-output-left";
              "Mod+Shift+J" = "window-move-down";
              "Mod+Shift+K" = "window-move-up";
              "Mod+Shift+L" = "window-move-or-output-right";

              "Mod+Home" = "column-focus-first";
              "Mod+End" = "column-focus-last";
              "Mod+Shift+Home" = "column-move-to-first";
              "Mod+Shift+End" = "column-move-to-last";

              "Mod+Ctrl+Left" = "output-focus-left";
              "Mod+Ctrl+Down" = "output-focus-down";
              "Mod+Ctrl+Up" = "output-focus-up";
              "Mod+Ctrl+Right" = "output-focus-right";
              "Mod+Ctrl+H" = "output-focus-left";
              "Mod+Ctrl+J" = "output-focus-down";
              "Mod+Ctrl+K" = "output-focus-up";
              "Mod+Ctrl+L" = "output-focus-right";

              "Mod+F" = "window-toggle-maximize";
              "Mod+Shift+F" = "window-toggle-fullscreen";
              "Mod+M" = "column-toggle-tabbed";
              "Mod+A" = "overview-toggle";
              "Mod+S" = "window-toggle-floating";
              "Mod+C" = "window-cycle-primary-extent";

              "Mod+X" = "window-modify-primary-extent +0.05";
              "Mod+Shift+X" = "window-modify-primary-extent -0.05";
              # niri's expand-column-to-available-width has no equivalent; full width instead.
              "Mod+Ctrl+X" = "window-set-primary-extent 1.0";
              "Mod+Z" = "window-modify-secondary-extent +0.05";
              "Mod+Shift+Z" = "window-modify-secondary-extent -0.05";

              "Mod+Shift+WheelDown" = "workspace-next";
              "Mod+Shift+WheelUp" = "workspace-previous";
              "Mod+WheelDown" = "window-focus-right";
              "Mod+WheelUp" = "window-focus-left";
              "Mod+WheelRight" = "window-focus-right";
              "Mod+WheelLeft" = "window-focus-left";
              "Mod+Shift+WheelRight" = "column-move-right";
              "Mod+Shift+WheelLeft" = "column-move-left";

              "Mod+Comma" = "window-consume-or-expel-left";
              "Mod+Period" = "window-consume-or-expel-right";

              # umbriel has no screenshot actions. The others copy to the clipboard only, like
              # niri's built-in screenshots with screenshot-path null.
              "Mod+Print" = "spawn screenshot";
              "Print" = "spawn dms screenshot --no-file";
              "Ctrl+Print" = "spawn dms screenshot full --no-file";
              "Alt+Print" = "spawn dms screenshot window --no-file";

              "Mod+Slash" = "cheatsheet-toggle";

              "Mod+D" = "spawn niri-dynamic-workspaces";
              "Mod+Ctrl+D" = "spawn niri-dynamic-workspaces delete";
              "Mod+Shift+D" = "spawn niri-dynamic-workspaces move-window";

              "Mod+Return" = "spawn ${workspaceKitty}";
              "Mod+Shift+Return" = "spawn ${workspaceKitty} --in-column";
              "Mod+Backspace" = "window-close";
              # SIGKILL to the client, what window-kill does under niri.
              "Mod+Shift+Backspace" = "window-kill";

              # niri's built-ins: Mod+middle-drag pans; Alt/Mod+Tab's recent-windows switcher has
              # no umbriel equivalent beyond flipping to the last-focused window.
              "Mod+MouseMiddle" = "layout-scroll-drag";
              "Alt+Tab" = "window-focus-last";
              "Mod+Tab" = "window-focus-last";
            }
            // workspaceBinds
            // lib.optionalAttrs config.fireproof.dev.enable {
              "Mod+T" = "scratchpad-toggle sublime-merge";
              "Mod+5" = workspaceBinds."Mod+T";
            };
        };
      };

      home.file = lib.mkIf config.fireproof.dev.enable {
        ".local/bin/smerge" = {
          executable = true;
          text =
            lib.replaceStrings
            ["@shell@" "@jq@" "@smerge@"]
            [pkgs.runtimeShell (lib.getExe pkgs.jq) smerge]
            (builtins.readFile ./scripts/smerge.sh);
        };
      };

      xdg.configFile."umbriel/config.toml".source = lib.mkForce validated;
    };
  };
}
