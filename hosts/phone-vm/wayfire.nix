# Wayfire in one pocketnix window, a trial of a nested desktop: the only
# nested, CPU-rendered compositor with touchscreen gestures.
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    mono = config.fireproof.theme.font.monoFamily;

    term = "${lib.getExe pkgs.foot} -o font='${mono}:size=10'";
    drawer = "${lib.getExe pkgs.nwg-drawer} -ovl -c 3 -is 56 -spacing 12 -nofs -term '${lib.getExe pkgs.foot}'";

    # The panel's buttons, over Wayfire's IPC socket: close, overview, workspaces.
    ipc = pkgs.writers.writePython3Bin "wayfire-phone-ipc" {} ''
      import json
      import os
      import socket
      import struct
      import sys


      def call(sock, method, data=None):
          msg = json.dumps({"method": method, "data": data or {}}).encode()
          sock.sendall(struct.pack("<I", len(msg)) + msg)
          size = struct.unpack("<I", sock.recv(4))[0]
          body = b""
          while len(body) < size:
              body += sock.recv(size - len(body))
          return json.loads(body)


      sock = socket.socket(socket.AF_UNIX)
      sock.connect(os.environ["WAYFIRE_SOCKET"])
      action = sys.argv[1]
      if action == "close":
          view = call(sock, "window-rules/get-focused-view").get("info")
          if view:
              call(sock, "window-rules/close-view", {"id": view["id"]})
      else:
          call(sock, action)
    '';

    panel = pkgs.writeText "wf-shell.ini" ''
      [panel]
      position = top
      minimal_height = 40
      background_color = \#${c.black}FF
      widgets_left = launchers window-list
      widgets_center = none
      widgets_right = clock
      clock_format = %H:%M
      launchers_size = 28
      launchers_spacing = 14
      launcher_cmd_a_apps = ${drawer}
      launcher_icon_a_apps = view-app-grid-symbolic
      launcher_cmd_b_overview = ${lib.getExe ipc} scale/toggle
      launcher_icon_b_overview = view-grid-symbolic
      launcher_cmd_c_term = ${term}
      launcher_icon_c_term = utilities-terminal
      launcher_cmd_d_close = ${lib.getExe ipc} close
      launcher_icon_d_close = window-close-symbolic
    '';

    # @layout@: pocketnix passes the keyboard layout in the environment, and
    # Wayfire reads it only from its config.
    wayfireConfig = pkgs.writeText "wayfire-phone.ini" ''
      [core]
      plugins = alpha animate autostart command decoration expo foreign-toplevel gtk-shell ipc ipc-rules move place resize scale vswitch wayfire-shell wm-actions xdg-activation
      preferred_decoration_mode = server
      xwayland = false
      vwidth = 3
      vheight = 1
      background_color = \#${c.bg}FF
      close_top_view = <super> KEY_Q

      [input]
      xkb_layout = @layout@

      # Every window full screen, as on a phone; the overview switches between them.
      [place]
      mode = maximize

      [decoration]
      title_height = 36
      border_size = 0
      button_order = close
      font = Inter
      active_color = \#${c.uiAlt}FF
      inactive_color = \#${c.bgAlt}FF
      font_color = \#${c.fg}FF

      [animate]
      open_animation = fade
      close_animation = fade
      duration = 150ms

      # Three-finger swipes: up for the windows, down for the workspaces,
      # sideways to the next workspace.
      [scale]
      toggle = <super> KEY_P | swipe up 3
      duration = 300ms
      spacing = 20
      inactive_alpha = 1.0
      bg_color = \#${c.black}E6
      text_color = \#${c.fg}FF

      [expo]
      toggle = <super> KEY_E | swipe down 3
      background = \#${c.black}FF

      [vswitch]
      binding_left = <super> <alt> KEY_LEFT | swipe right 3
      binding_right = <super> <alt> KEY_RIGHT | swipe left 3
      duration = 200ms

      [wm-actions]
      toggle_fullscreen = <super> KEY_F

      [command]
      binding_term = <super> KEY_ENTER
      command_term = ${term}
      binding_apps = <super> KEY_D
      command_apps = ${drawer}

      [autostart]
      autostart_wf_shell = false
      panel = ${pkgs.wayfirePlugins.wf-shell}/bin/wf-panel -c ${panel}
    '';

    wayfirePhone = pkgs.writeShellApplication {
      name = "wayfire-phone";
      runtimeInputs = [pkgs.wayfire pkgs.gnused];
      text = ''
        export WLR_RENDERER=pixman XDG_CURRENT_DESKTOP=wayfire
        config="$XDG_RUNTIME_DIR/wayfire-phone.ini"
        sed "s/@layout@/''${XKB_DEFAULT_LAYOUT:-us}/" ${wayfireConfig} > "$config"
        exec wayfire -c "$config"
      '';
    };
  in {
    # The bar needs Compact; at the phone's own density it doesn't fit.
    pocketnix.guest.gui.appDefaults.wayfire-nested.size = "compact";

    environment.systemPackages = [
      (pkgs.makeDesktopItem {
        name = "wayfire-nested";
        desktopName = "Wayfire";
        comment = "Wayfire desktop in a window, with touch gestures";
        exec = lib.getExe wayfirePhone;
        icon = "preferences-desktop-display";
        categories = ["System"];
      })
    ];
  };
}
