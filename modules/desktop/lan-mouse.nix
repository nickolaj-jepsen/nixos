# Lan Mouse — share keyboard/mouse across machines over LAN by crossing the
# screen edge. Peer-to-peer (each end both captures and emulates), DTLS-encrypted.
#
# Why this and not input-leap/deskflow on niri: those capture via the
# `org.freedesktop.portal.InputCapture` portal, which niri does not implement.
# Lan Mouse instead auto-selects its layer-shell capture backend on niri (a
# wlr-layer-shell surface, which niri does support), so edge capture works here.
#
# config.toml is intentionally NOT managed declaratively: Lan Mouse writes peer
# TLS fingerprints into it at pairing time, so it must stay mutable. Pair and add
# the remote screen via the GUI (`lan-mouse`) on first run; the daemon below picks
# it up.
{
  flake.modules.nixos.lan-mouse = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.lan-mouse.enable {
      networking.firewall.allowedUDPPorts = [4242];
    };
  };

  flake.modules.homeManager.lan-mouse = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.lan-mouse.enable && pkgs.stdenv.isLinux) {
      home.packages = [pkgs.unstable.lan-mouse];

      systemd.user.services.lan-mouse = {
        Unit = {
          Description = "Lan Mouse daemon";
          After = ["graphical-session.target"];
          PartOf = ["graphical-session.target"];
        };
        Service = {
          ExecStart = "${lib.getExe pkgs.unstable.lan-mouse} daemon";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    };
  };
}
