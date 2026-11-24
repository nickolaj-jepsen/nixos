{inputs, ...}: {
  flake.modules.nixos.mango = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mango = config.programs.mango.package;

    # niri-session for mango: the login shell's environment into the user manager, then mango as
    # mango.service in session.slice (niri.service's place), and graphical-session.target torn
    # down when it exits. The target itself starts from mango's autostart, once WAYLAND_DISPLAY
    # is known (wayland.windowManager.mango.systemd).
    session = pkgs.writeShellScriptBin "mango-session" ''
      if [ "''${1:-}" != -l ] && [ -n "''${SHELL:-}" ]; then
        exec ${pkgs.bash}/bin/bash -c "exec -l '$SHELL' -c 'exec $0 -l'"
      fi
      if systemctl --user -q is-active mango.service; then
        echo 'A mango session is already running.' >&2
        exit 1
      fi
      systemctl --user reset-failed
      # A niri session earlier in this boot leaves its socket behind.
      unset NIRI_SOCKET
      systemctl --user unset-environment NIRI_SOCKET
      systemctl --user import-environment
      ${pkgs.dbus}/bin/dbus-update-activation-environment --all
      systemctl --user --wait start mango.service
      systemctl --user stop graphical-session.target
      systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP MANGO_INSTANCE_SIGNATURE
    '';
    sessionPackage =
      pkgs.writeTextDir "share/wayland-sessions/mango.desktop" ''
        [Desktop Entry]
        Name=Mango
        Comment=A dwl-based Wayland compositor
        Exec=${lib.getExe session}
        Type=Application
        DesktopNames=mango
      ''
      // {providedSessions = ["mango"];};
  in {
    imports = [inputs.mangowm.nixosModules.mango];

    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.mango.enable) {
      programs.mango = {
        enable = true;
        # Its own entry runs bare `mango`, which never stops graphical-session.target.
        addLoginEntry = false;
      };
      # mango's portals.conf takes wlr for capture; keep niri's file picker.
      xdg.portal.config.mango."org.freedesktop.impl.portal.FileChooser" = "gnome";
      # On XDG_DATA_DIRS, where dms-greeter lists sessions. Autologin always lands in niri, so
      # with it on, start mango by running mango-session from a TTY.
      services.displayManager.sessionPackages = [sessionPackage];
      # niri inhibits logind and suspends on the power key; mango leaves it to logind, whose
      # default is poweroff. Under niri this setting is never reached.
      services.logind.settings.Login.HandlePowerKey = "suspend";
      # A packaged unit, like niri.service: one declared through systemd.user.services gets
      # NixOS's minimal PATH, which would replace the login environment mango-session imports.
      systemd.packages = [
        (pkgs.writeTextDir "lib/systemd/user/mango.service" ''
          [Unit]
          Description=mango, a dwl-based Wayland compositor

          [Service]
          # Part of the shell, never an oomd candidate; its spawns go to app.slice (mango-app).
          Slice=session.slice
          ExecStart=${lib.getExe mango}
        '')
      ];
      environment.systemPackages = [session];
    };
  };
}
