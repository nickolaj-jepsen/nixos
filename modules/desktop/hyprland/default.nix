{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.fireproof;
  primaryMonitorName =
    if builtins.length config.monitors > 0
    then (builtins.elemAt config.monitors 0).name
    else "";

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
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    security.polkit.enable = true;
    services.dbus.enable = true;

    hardware = {
      graphics = {
        enable = true;
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
            "col.active_border" = "rgb(cf6a4c)";
            "col.inactive_border" = "rgb(343331)";
            layout = "dwindle";
          };
          cursor = {
            no_warps = true;
          };
          misc = {
            focus_on_activate = true;
            disable_hyprland_logo = true;
            force_default_wallpaper = 0;
            middle_click_paste = false;
            font_family = "Hack Nerd Font";
          };

          decoration = {
            rounding = 4;
            shadow = {
              enabled = true;
              range = 4;
              render_power = 3;
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
          bind = [
            "SUPER, RETURN, exec, ${getExe config.programs.uwsm.package} app -- ${cfg.default-apps.terminal}"
            "SUPER, BACKSPACE, killactive"
            "SUPER, SPACE, exec, ${getExe config.programs.uwsm.package} app -- walker"
            "SUPER, p, exec, ${getExe config.programs.uwsm.package} app -- loginctl lock-session"
            "SUPER, S, togglefloating"
            "SUPER, A, pseudo"
            "SUPER, D, fullscreen"
            "SUPER, BACKSLASH, togglesplit"
            "SUPER, M, togglegroup"
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
        };
      };
    };
  };
}
