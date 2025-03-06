{
  lib,
  config,
  inputs,
  pkgs,
  ...
}:
with lib; let
  cfg = config.fireproof;
  primaryMonitorName = (builtins.head config.monitors).name or "";

  hyprPkgs = {
    inherit (inputs.hyprland.packages.${pkgs.system}) hyprland;
    inherit (inputs.hyprland.packages.${pkgs.system}) xdg-desktop-portal-hyprland;
    mesa = inputs.hyprland.inputs.nixpkgs.legacyPackages.${pkgs.system}.mesa.drivers;
    mesa32 = inputs.hyprland.inputs.nixpkgs.legacyPackages.${pkgs.system}.pkgsi686Linux.mesa.drivers;
  };

  color = {
    bg = "rgb(1C1B1A)";
    ui = "rgb(343331)";
    fg = "rgb(DAD8CE)";
    accent = "rgb(CF6A4C)";
    black = "rgb(100F0F)";
    transparent = "rgba(00000000)";
  };

  record_script = pkgs.writeShellScriptBin "record_script" ''
    DIR="$HOME/recordings"
    FILE="$DIR/$(date '+%Y-%m-%d_%H.%M.%S').mp4"

    mkdir -p $DIR
    if pgrep -f ${lib.getExe pkgs.wf-recorder} > /dev/null; then
        pkill ${lib.getExe pkgs.wf-recorder}
        ${pkgs.libnotify}/bin/notify-send "Recording Stopped" "Recording saved to $FILE"
    else
        # Stolen from grimblast
        FULLSCREEN_WORKSPACES="$(hyprctl workspaces -j | jq -r 'map(select(.hasfullscreen) | .id)')"
        WORKSPACES="$(hyprctl monitors -j | jq -r '[(foreach .[] as $monitor (0; if $monitor.specialWorkspace.name == "" then $monitor.activeWorkspace else $monitor.specialWorkspace end)).id]')"
        WINDOWS="$(hyprctl clients -j | jq -r --argjson workspaces "$WORKSPACES" --argjson fullscreenWorkspaces "$FULLSCREEN_WORKSPACES" 'map((select(([.workspace.id] | inside($workspaces)) and ([.workspace.id] | inside($fullscreenWorkspaces) | not) or .fullscreen > 0)))')"

        GEOMETRY=$(echo "$WINDOWS" | jq -r '.[] | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' | ${lib.getExe pkgs.slurp})

        # ${pkgs.libnotify}/bin/notify-send "Starting recording" "Recording in 3 seconds" -a "record_script" -t 1000
        # sleep 1
        # ${pkgs.libnotify}/bin/notify-send "Starting recording" "Recording in 2 seconds" -a "record_script"  -t 1000
        # sleep 1
        # ${pkgs.libnotify}/bin/notify-send "Starting recording" "Recording in 1 second" -t 1000
        # sleep 1

        ${pkgs.wf-recorder}/bin/wf-recorder --pixel-format yuv420p -f "$FILE" -t --geometry "$GEOMETRY" & disown
        ${pkgs.wl-clipboard}/bin/wl-copy < "$FILE"
    fi
  '';

  mkKeyboard = name: {
    inherit name;
    kb_layout = "eu";
  };
  mkMouse = name: sensitivity: {
    inherit name;
    inherit sensitivity;
  };
in {
  imports = [
    ./hyprpolkitagent.nix
    ./hyprpaper.nix
  ];

  config = {
    programs.uwsm.enable = true;
    programs.hyprland = {
      package = hyprPkgs.hyprland;
      portalPackage = hyprPkgs.xdg-desktop-portal-hyprland;
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    security.polkit.enable = true;
    services.dbus.enable = true;
    services.systembus-notify.enable = true;

    hardware = {
      graphics = {
        enable = true;
        package = hyprPkgs.mesa;
        package32 = hyprPkgs.mesa32;
      };
    };

    environment.sessionVariables.NIXOS_OZONE_WL = "1";
    environment.systemPackages = with pkgs; [
      hyprcursor
    ];

    fireproof.home-manager = {
      wayland.windowManager.hyprland = {
        enable = true;
        xwayland.enable = true;
        systemd.enable = false; # Conficts with UWSM

        settings = {
          env = [
            "HYPRCURSOR_THEME,Adwaita"
            "HYPRCURSOR_SIZE,24"
          ];
          monitor =
            map (
              m: let
                name =
                  if m.name != null
                  then m.name
                  else "";
                resolution =
                  if m.resolution != null
                  then m.resolution
                  else "preferred";
                refreshRate =
                  if m.refreshRate != null
                  then "@${builtins.toString m.refreshRate}"
                  else "";
                position =
                  if m.position != null
                  then m.position
                  else "auto";
                transform =
                  if m.transform != null
                  then ", transform, ${builtins.toString m.transform}"
                  else "";
              in "${name}, ${resolution}${refreshRate}, ${position}, 1${transform}"
            )
            config.monitors;

          exec = ["systemctl --user start hyprpaper"];

          input = {
            # Most unknown keyboards will be of the DK layout, we set known keyboards to eu in `devices`
            kb_layout = "dk";
            kb_options = "caps:backspace";

            # Cursor focus will be detached from keyboard focus. Clicking on a window will move keyboard focus to that window.
            follow_mouse = 2;

            touchpad = {
              natural_scroll = false;
            };

            sensitivity = 0;
            accel_profile = "flat";
          };

          workspace =
            if primaryMonitorName != ""
            then [
              "1, monitor:${primaryMonitorName}, persistent:true, default:true"
              "2, monitor:${primaryMonitorName}, persistent:true"
              "3, monitor:${primaryMonitorName}, persistent:true"
              "4, monitor:${primaryMonitorName}, persistent:true"
              "5, monitor:${primaryMonitorName}, persistent:true"
            ]
            else [
              "1, persistent:true, default:true"
              "2, persistent:true"
              "3, persistent:true"
              "4, persistent:true"
              "5, persistent:true"
            ];

          # Names can be found with:
          # $ hyprctl devices -j | jq '.["keyboards"].[].name' -r | grep -vE "(system|consumer)-control"
          device =
            [
              # $ hyprctl devices -j | jq '.["mice"].[].name' -r
              (mkMouse "logitech-usb-ps/2-optical-mouse" 0.2)
            ]
            ++ map mkKeyboard [
              "splitkb-kyria-rev1"
              "zsa-technology-labs-inc-ergodox-ez-shine"
              "mattia-dal-ben-redox_wireless"
              "zsa-technology-labs-inc-ergodox-ez-shine-keyboard"
            ];

          general = {
            gaps_in = 5;
            gaps_out = 10;
            border_size = 2;
            "col.active_border" = color.accent;
            "col.inactive_border" = color.ui;
            layout = "dwindle";
          };
          cursor = {
            no_warps = true;
          };
          misc = {
            focus_on_activate = true;
            disable_hyprland_logo = true;
            background_color = color.bg;
            force_default_wallpaper = 0;
            middle_click_paste = false;
            font_family = "Hack Nerd Font";
          };

          decoration = {
            rounding = 8;
            rounding_power = 4;
            shadow = {
              enabled = true;
              color = "rgba(1a1a1aee)";
            };
          };
          animations = {
            enabled = true;
            animation = [
              "windows, 1, 4, default"
              "windowsOut, 1, 4, default, popin 80%"
              "border, 1, 10, default"
              "borderangle, 1, 8, default"
              "fade, 1, 7, default"
              "workspaces, 1, 3, default"
            ];
          };
          dwindle = {
            pseudotile = true;
            preserve_split = true;
            force_split = 2;
            use_active_for_splits = true;
          };
          group = {
            auto_group = false;
            "col.border_inactive" = color.bg;
            "col.border_active" = color.accent;
            groupbar = {
              enabled = true;
              font_size = 12;
              gradients = false;
              height = 16;
              indicator_height = 2;
              "col.inactive" = color.ui;
              "col.active" = color.accent;
              "text_color" = color.fg;
            };
          };

          bind = [
            "SUPER, RETURN, exec, ${getExe config.programs.uwsm.package} app -- ${cfg.default-apps.terminal}"
            "SUPER, BACKSPACE, killactive"
            "SUPER, SPACE, exec, astal launcher"
            "SUPER, semicolon, exec, astal launcher .e"
            "SUPER, p, exec, ${getExe config.programs.uwsm.package} app -- loginctl lock-session"

            ", Print, exec, ${lib.getExe pkgs.grimblast} save area - | ${lib.getExe pkgs.satty} -f -"
            "SHIFT, Print, exec, ${lib.getExe pkgs.grimblast} --freeze save area - | ${lib.getExe pkgs.satty} -f -"
            "CTRL, Print, exec, ${lib.getExe record_script}"

            "SUPER, S, togglefloating"
            "SUPER, A, pseudo"
            "SUPER, D, fullscreen"
            "SUPER, BACKSLASH, togglesplit"

            "SUPER, left, movefocus, l"
            "SUPER, right, movefocus, r"
            "SUPER, up, movefocus, u"
            "SUPER, down, movefocus, d"

            "SUPER, h, movefocus, l"
            "SUPER, l, movefocus, r"
            "SUPER, k, movefocus, u"
            "SUPER, j, movefocus, d"
            "SUPER, p, submap, preselect"

            "SUPER, q, workspace, 1"
            "SUPER, w, workspace, 2"
            "SUPER, e, workspace, 3"
            "SUPER, r, workspace, 4"
            "SUPER, t, workspace, 5"
            "SUPER SHIFT, q, movetoworkspace, 1"
            "SUPER SHIFT, w, movetoworkspace, 2"
            "SUPER SHIFT, e, movetoworkspace, 3"
            "SUPER SHIFT, r, movetoworkspace, 4"
            "SUPER SHIFT, t, movetoworkspace, 5"

            "SUPER SHIFT, h, workspace, r-1"
            "SUPER SHIFT, l, workspace, r+1"

            "SUPER, M, togglegroup"
            "SUPER, tab, changegroupactive, f"
            "SUPER SHIFT, tab, changegroupactive, b"
          ];
          bindm = [
            "SUPER, mouse:272, movewindow"
            "SUPER, mouse:273, resizewindow"
          ];
          layerrule = [
            "noanim, gtk4-layer-shell"
          ];
          windowrulev2 = [
            # Screenshots
            "float,class:^(com.gabm.satty)$"
            "dimaround,class:^(com.gabm.satty)$"

            # Firefox
            "float,class:^(firefox)$,title:^(Picture-in-Picture)$"
            "float,class:^(firefox)$,title:^(Library)$"
            "float,class:^(firefox)$,title:^(Bitwarden Password Manager)$"

            # JetBrains
            "center,class:^(jetbrains-.*)$,title:^$,floating:1"
            "noinitialfocus,class:^(jetbrains-.*)$,title:^$,floating:1"
            "noanim,class:^(jetbrains-.*)$,title:^$,floating:1"

            "center,class:^(jetbrains-.*)$,title:^(splash)$,floating:1"
            "nofocus,class:^(jetbrains-.*)$,title:^(splash)$,floating:1"
            "noborder,class:^(jetbrains-.*)$,title:^(splash)$,floating:1"
          ];
        };
      };
    };
  };
}
