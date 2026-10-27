# The janitor (docs/janitor.md). The CLI itself is pkgs/janitor; this leaf
# schedules it, tells it the home layout and puts it on PATH, so the agent
# wrappers (claude-code, claude-work, pi) can ask it where their TMPDIR goes.
{fpLib, ...}: {
  flake.modules.homeManager.janitor = {
    config,
    lib,
    pkgs,
    ...
  }: let
    path = fpLib.homePath config;
  in {
    config = lib.mkIf config.fireproof.janitor.enable {
      home.packages = [pkgs.janitor];

      # The home layout as the CLI reads it, so every caller (timers, widget,
      # wrappers, a terminal) agrees on the roster, scratch and the strays.
      xdg.configFile."janitor/layout.json".text = builtins.toJSON {
        repoParents = [(path "dev")];
        repoSingles = [(path "nixos")];
        scratch = path "scratch";
        # macOS creates these itself and won't let them go.
        roots = fpLib.homeRoots config ++ lib.optionals pkgs.stdenv.isDarwin ["Applications" "Library" "Movies"];
        # Roots that moved, so a box still on the old layout is told where to.
        hints = {
          obsidian = path "notes";
          models = "${config.xdg.dataHome}/llm/models";
        };
      };

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
      # worktrees, transcripts past their month, and the cached plan.
      systemd.user.services.janitor-repo = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim merged branches, finished worktrees and old transcripts";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.janitor} run repo";
          Nice = 10;
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
        };
      };

      systemd.user.timers.janitor-repo = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Reclaim merged branches, finished worktrees and old transcripts";
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
