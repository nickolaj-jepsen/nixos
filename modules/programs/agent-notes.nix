# Agent notes (docs/notes.md). The CLI is pkgs/agent-notes; this leaf puts it on
# PATH, and the agent wrappers and git hook call it by that path.
#
# The store sits under the agents' data directory, so it is gated by dev.enable
# rather than a feature of its own: every agent writes notes.
{
  flake.modules.homeManager.agent-notes = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [pkgs.agent-notes];

      # Session scratch (`tmp/<repo>/<pid>`, or Claude Code's session-keyed folders
      # under `tmp/<repo>`) untouched for 3 days goes on a daily timer. Not a
      # `systemd-tmpfiles` rule: tmpfiles gives up on the first directory it may
      # not open or unlink — a read-only Go module cache, or a `d---------` a test
      # bed left behind — and with it the rest of that multi-gigabyte session.
      # `reap` chmods what it may and removes an empty directory it may not enter.
      # The `<repo>` level stays, so a checkout's `.agents/tmp` link never dangles.
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
