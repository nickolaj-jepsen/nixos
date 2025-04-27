{pkgs, ...}: {
  fireproof.home-manager.services.mako.enable = true;
  systemd.user.services."mako" = {
    description = "Mako notification daemon";
    documentation = ["man:mako(1)"];
    partOf = ["graphical-session.target"];
    after = ["graphical-session.target"];
    serviceConfig = {
      Type = "dbus";
      BusName = "org.freedesktop.Notifications";
      ExecCondition = "/bin/sh -c '[ -n \"$WAYLAND_DISPLAY\" ]'";
      ExecReload = "${pkgs.mako}/bin/mako reload";
      ExecStart = "${pkgs.mako}/bin/mako";
    };
    wantedBy = ["graphical-session.target"];
  };
}
