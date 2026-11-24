{inputs, ...}: {
  flake.modules.nixos.mango = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mango = config.programs.mango.package;

    # niri-session's job for mango: a login shell's environment, then graphical-session.target
    # torn down on exit so DMS and friends don't outlive the compositor. The target itself is
    # started from mango's autostart (wayland.windowManager.mango.systemd).
    session = pkgs.writeShellScript "mango-session" ''
      if [ "''${1:-}" != -l ] && [ -n "''${SHELL:-}" ]; then
        exec ${pkgs.bash}/bin/bash -c "exec -l '$SHELL' -c 'exec $0 -l'"
      fi
      systemctl --user reset-failed
      # A niri session earlier in this boot leaves its socket in the manager's environment.
      systemctl --user unset-environment NIRI_SOCKET
      ${lib.getExe mango}
      systemctl --user stop graphical-session.target
      systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP MANGO_INSTANCE_SIGNATURE
    '';
    sessionPackage =
      pkgs.writeTextDir "share/wayland-sessions/mango.desktop" ''
        [Desktop Entry]
        Name=Mango
        Comment=A dwl-based Wayland compositor
        Exec=${session}
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
      # On XDG_DATA_DIRS, where dms-greeter lists sessions; autologin still lands in niri.
      services.displayManager.sessionPackages = [sessionPackage];
    };
  };
}
