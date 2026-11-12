{
  flake.modules.homeManager.nirius = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      # niri helpers (scratchpad, focus-or-spawn, marks); zed-scratch's scratchpad lives here.
      home.packages = [pkgs.nirius];

      systemd.user.services.niriusd = {
        Unit = {
          Description = "nirius daemon";
          After = ["graphical-session.target"];
          PartOf = ["graphical-session.target"];
          # The Hyprland session shares graphical-session.target but has no niri socket.
          ConditionEnvironment = "NIRI_SOCKET";
        };
        Service = {
          ExecStart = lib.getExe' pkgs.nirius "niriusd";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    };
  };
}
