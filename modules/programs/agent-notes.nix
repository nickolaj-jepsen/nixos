# The CLI is pkgs/agent-notes; wrappers and the git hook call it from PATH.
# The store is gated by dev.enable because every agent writes notes. It is not
# in /home snapshots or off-host backups.
{
  flake.modules.homeManager.agent-notes = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [pkgs.agent-notes];

      # Reap session scratch untouched for 3 days. Keep the <repo> level so a
      # checkout's .agents/tmp link never dangles; reap.py handles read-only trees.
      systemd.user.services.agent-notes-reap = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Age out agent session scratch older than three days";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.agent-notes} reap --max-age 3d";
          IOSchedulingClass = "idle";
          Nice = 10;
        };
      };
      systemd.user.timers.agent-notes-reap = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Daily age-out of agent session scratch";
        Install.WantedBy = ["timers.target"];
        Timer = {
          OnCalendar = "daily";
          RandomizedDelaySec = "1h";
          Persistent = true;
        };
      };
    };
  };
}
