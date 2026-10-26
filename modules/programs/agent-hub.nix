{
  flake.modules.homeManager.agent-hub = {
    config,
    lib,
    pkgs,
    ...
  }: let
    fp = config.fireproof;
  in {
    # The hub only has a bar to show in, so it runs where DMS does.
    config = lib.mkIf (fp.dev.agent-hub.enable && pkgs.stdenv.isLinux) {
      home.packages = [pkgs.agent-hub];
      xdg.configFile."agent-hub/config.json".text = builtins.toJSON {
        # The running compositor's IPC, and a user unit has no login PATH.
        niri = lib.getExe pkgs.niri-unstable;
        notifySend = lib.getExe' pkgs.libnotify "notify-send";
        busctl = lib.getExe' pkgs.systemd "busctl";
        # The bare package, without the wrapper's plugin dirs, for the turn classifier.
        claude = lib.getExe config.programs.claude-code.package;
      };

      # Everything but Claude's dialog labels is read back from the registry or the
      # hub's state file, so a restart loses at most a label.
      systemd.user.services.agent-hub = {
        Unit.Description = "agent-hub, the desktop hub for coding-agent sessions";
        Service = {
          ExecStart = "${lib.getExe pkgs.agent-hub} daemon";
          Restart = "always";
          RestartSec = 2;
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    };
  };

  perSystem = {pkgs, ...}: {
    checks.agent-hub-tests =
      pkgs.runCommand "agent-hub-tests" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        cp ${../../pkgs/agent-hub/tests/test_hub.py} test_hub.py
        AGENT_HUB=${../../pkgs/agent-hub/agent_hub.py} python3 -m unittest -v test_hub
        touch $out
      '';
  };
}
