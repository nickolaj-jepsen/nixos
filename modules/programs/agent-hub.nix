{
  flake.modules.homeManager.agent-hub = {
    config,
    lib,
    pkgs,
    ...
  }: let
    fp = config.fireproof;
    exe = lib.getExe pkgs.agent-hub;
    # Only a niri desktop has windows to focus and toasts to show; elsewhere the hub
    # serves the agents' own TUIs.
    desktop = fp.desktop.enable && pkgs.stdenv.isLinux;
  in {
    config = lib.mkIf fp.dev.agent-hub.enable (lib.mkMerge [
      {
        home.packages = [pkgs.agent-hub];
        xdg.configFile."agent-hub/config.json".text = builtins.toJSON ({
            # The bare package, without the wrapper's plugin dirs, for the readings.
            claude = lib.getExe config.programs.claude-code.package;
            # A user unit has no login PATH: working trees and branches for the readings.
            git = lib.getExe pkgs.git;
          }
          // lib.optionalAttrs desktop {
            # The running compositor's IPC, and a user unit has no login PATH.
            niri = lib.getExe pkgs.niri-unstable;
            notifySend = lib.getExe' pkgs.libnotify "notify-send";
            busctl = lib.getExe' pkgs.systemd "busctl";
            # What resumes an ended session from the popout, spawned through niri as Mod+Return is.
            terminal = ["ghostty" "--working-directory={cwd}" "-e"];
          });
      }

      # Everything but Claude's dialog labels is read back from the registry or the
      # hub's state file, so a restart loses at most a label.
      (lib.mkIf pkgs.stdenv.isLinux {
        systemd.user.services.agent-hub = {
          Unit.Description = "agent-hub, the hub for live coding-agent sessions";
          Service = {
            ExecStart = "${exe} daemon";
            Restart = "always";
            RestartSec = 2;
          };
          Install.WantedBy = ["default.target"];
        };
      })

      (lib.mkIf pkgs.stdenv.isDarwin {
        launchd.agents.agent-hub = {
          enable = true;
          config = {
            ProgramArguments = [exe "daemon"];
            KeepAlive = true;
            RunAtLoad = true;
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/agent-hub.log";
          };
        };
      })
    ]);
  };
}
