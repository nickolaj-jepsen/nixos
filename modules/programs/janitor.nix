# The janitor (docs/janitor.md). The CLI itself is pkgs/janitor; this leaf only
# schedules it and puts it on PATH, so the agent wrappers (claude-code,
# claude-work, pi) can ask it where their TMPDIR goes.
{
  flake.modules.homeManager.janitor = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.janitor.enable {
      home.packages = [pkgs.janitor];

      # Cheap and frequent: agent temp, finished jobs, other agents' strays. At
      # login it clears what a crash or a SIGKILL left behind, then every quarter
      # hour it enforces the budget.
      systemd.user.services.janitor-tmp = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim dead coding-agent temp sessions";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.janitor} run tmp";
          # This walks metadata over files other units are writing, so it yields
          # to builds and to the agents themselves.
          Nice = 10;
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
        };
      };

      systemd.user.timers.janitor-tmp = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim dead coding-agent temp sessions";
        Timer = {
          OnStartupSec = "2min";
          OnUnitActiveSec = "15min";
        };
        Install.WantedBy = ["timers.target"];
      };

      # Once a day, and after a laptop wakes: merged branches, finished
      # worktrees, finished jobs, and the cached plan.
      systemd.user.services.janitor-repo = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim merged branches and finished worktrees";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.janitor} run repo";
          Nice = 10;
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
        };
      };

      systemd.user.timers.janitor-repo = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim merged branches and finished worktrees";
        Timer = {
          OnCalendar = "04:00";
          Persistent = true;
          OnStartupSec = "5min";
        };
        Install.WantedBy = ["timers.target"];
      };
    };
  };
}
