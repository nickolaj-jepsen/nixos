# The agent temp janitor (docs/agent-tmp.md). The CLI itself is pkgs/agent-tmp;
# this leaf only schedules it and puts it on PATH, so the agent wrappers
# (claude-code, claude-work, pi) can ask it where their TMPDIR goes.
{
  flake.modules.homeManager.agent-tmp = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.agents.tmp.enable {
      home.packages = [pkgs.agent-tmp];

      # The only automatic caller. At login it clears what a crash or a SIGKILL
      # left behind, then every quarter hour it enforces the budget.
      systemd.user.services.agent-tmp-sweep = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim dead coding-agent temp sessions";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.agent-tmp} sweep";
          # A sweep is metadata walking over files other units are writing; it
          # has no deadline, so it yields to builds and to the agents themselves.
          Nice = 10;
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
        };
      };

      systemd.user.timers.agent-tmp-sweep = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim dead coding-agent temp sessions";
        Timer = {
          OnStartupSec = "2min";
          OnUnitActiveSec = "15min";
        };
        Install.WantedBy = ["timers.target"];
      };
    };
  };
}
