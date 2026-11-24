# Mirrors niri/settings.nix and niri/outputs.nix as far as mango allows.
{inputs, ...}: {
  flake.modules.homeManager.mango-settings = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    color = hex: "0x${hex}ff";
    enabledMonitors = lib.filter (m: m.name != null) config.fireproof.monitors;
    monitorRule = m:
      lib.concatStringsSep "," (
        ["name:^${m.name}$"]
        ++ (
          if !m.enable
          then ["disable:1"]
          else
            lib.optionals (m.resolution.width != null && m.resolution.height != null) [
              "width:${toString m.resolution.width}"
              "height:${toString m.resolution.height}"
            ]
            ++ lib.optional (m.refreshRateNiri != null) "refresh:${toString m.refreshRateNiri}"
            ++ [
              "x:${toString m.position.x}"
              "y:${toString m.position.y}"
              "scale:${toString m.scale}"
              # niri's transform is n×90° counter-clockwise; mango's rr 0-3 is the same.
              "rr:${toString (
                if m.transform == null
                then 0
                else m.transform
              )}"
              # VRR comes from the vrr_only_fullscreen window rules below, like niri's on-demand.
              "vrr:0"
            ]
        )
      );
  in {
    imports = [inputs.mangowm.hmModules.mango];

    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.mango.enable && pkgs.stdenv.isLinux) {
      wayland.windowManager.mango = {
        enable = true;
        # mango-session.target only starts from autostart.sh, which the module writes only
        # when this is non-empty. DMS needs the IPC socket to find mango.
        autostart_sh = "# graphical-session.target is started above.";
        # niri.service pulls in xdg-desktop-autostart.target (Bitwarden starts from it).
        systemd.xdgAutostart = true;
        systemd.variables = [
          "DISPLAY"
          "WAYLAND_DISPLAY"
          "XDG_CURRENT_DESKTOP"
          "XDG_SESSION_TYPE"
          "NIXOS_OZONE_WL"
          "XCURSOR_THEME"
          "XCURSOR_SIZE"
          "MANGO_INSTANCE_SIGNATURE"
        ];

        settings = {
          env = ["NIXOS_OZONE_WL,1"];

          monitor_rule = map monitorRule enabledMonitors;

          # Every tag scrolls like niri, with niri's presets on Mod+C. niri lets each app pick its
          # width (default-column-width {}); mango needs a proportion, so half. A lone column is
          # centred, where niri puts it at the left edge; mango has no option for that.
          tag_rule = ["id:*,layout_name:scroller"];
          scroller_default_proportion = 0.5;
          scroller_proportion_preset = "0.33333,0.5,0.66667,1.0";
          # The edge margin, subtracted from both sides: niri's 10 px gaps give niri's widths.
          scroller_structs = 10;
          # niri's focus-follows-mouse with max-scroll-amount 0%: never scroll to a hovered window.
          edge_scroller_pointer_focus = 0;

          gap_inner_horizontal = 10;
          gap_inner_vertical = 10;
          gap_outer_horizontal = 10;
          gap_outer_vertical = 10;

          border_px = 2;
          border_radius = 8;
          root_color = color c.bg;
          border_color = color c.ui;
          focus_color = color c.accent;
          # niri's border never set urgent-color, so its default.
          urgent_color = "0x9B0000ff";
          # Mod+F and the scratch note would otherwise get mango's own green and blue.
          maximized_screen_color = color c.accent;
          scratchpad_color = color c.accent;
          drop_color = "0x${c.accent}55";

          # Floating windows only, as in niri's is-floating shadow rule.
          shadows = 1;
          shadow_only_floating = 1;
          shadows_size = 5;
          shadows_blur = 30;
          shadows_position_x = 0;
          shadows_position_y = 5;
          shadows_color = "0x100F0F99";

          # niri blurs only what asks for it: DMS's layers (live, its xray off) and the terminals'
          # background_blur. mango has no blur protocol, so blur is on with the other windows
          # opted out below. blur_optimized would blur a cached wallpaper only, i.e. xray.
          blur = 1;
          blur_layer = 1;
          blur_optimized = 0;
          # niri's blur defaults.
          blur_params = {
            num_passes = 3;
            radius = 3;
            noise = 0.02;
            saturation = 1.5;
            brightness = 1.0;
            contrast = 1.0;
          };

          # niri's slowdown 0.8 and 150 ms ease-out-quad open/close.
          animations = 1;
          animation_type_open = "zoom";
          animation_type_close = "zoom";
          zoom_initial_ratio = 0.5;
          zoom_end_ratio = 0.5;
          animation_duration_open = 120;
          animation_duration_close = 120;
          animation_curve_open = "easeoutquad";
          animation_curve_close = "easeoutquad";
          animation_duration_move = 250;
          animation_duration_tag = 250;
          # Workspaces stack vertically in niri.
          tag_animation_direction = 0;
          workspace_overview_scroll_direction = "vertical";
          workspace_overview_scroll_ratio = 0.45; # niri's overview zoom
          # niri's default hot corner: top-left, 1 px. mango's opens its window grid, not the
          # workspace overview on Mod+A.
          enable_hotarea = 1;
          hotarea_corner = 0;
          hotarea_size = 1;

          cursor_theme = "Adwaita";
          cursor_size = 24;

          xkb_rules_layout = "eu";
          mouse_accel_profile = 1; # flat
          # niri: tap and natural-scroll set, disable-while-typing explicitly off.
          tap_to_click = 1;
          trackpad_natural_scrolling = 1;
          trackpad_disable_while_typing = 0;
          sloppy_focus = 1;
          warp_cursor = 0;
          disable_middle_paste = 1;
          focus_on_activate = 1;
          # Mod+H/L and Mod+Shift+H/L continue onto the next monitor, like niri's *-or-monitor-*.
          focus_cross_monitor = 1;
          exchange_cross_monitor = 1;
          # Mod+N finds the scratch note from any monitor instead of opening a second one.
          scratchpad_cross_monitor = 1;

          # niri's VRR is on while such a window is visible; mango's only while it is fullscreen.
          window_rule =
            [
              "is_floating:1,app_id:^org\\.gnome\\.NautilusPreviewer$"
              "no_blur:1,app_id:^(?!kitty$|com\\.mitchellh\\.ghostty$)"
              "vrr_only_fullscreen:1,app_id:^steam_app_"
              "vrr_only_fullscreen:1,app_id:^gamescope$"
              "vrr_only_fullscreen:1,app_id:^mpv$"
            ]
            # zed-scratch's note (Mod+N), as a named scratchpad at niri's reading width.
            ++ lib.optional config.fireproof.dev.enable
            "is_named_scratchpad:1,is_floating:1,width:864,height:0.6,app_id:^dev\\.zed\\.Zed$,title:^scratch\\.md( |$)";
        };
      };
    };
  };
}
