# Redact secrets out of agent transcripts (docs/janitor.md, "Transcripts"). The
# CLI is pkgs/transcript-sweep; this leaf puts it on PATH and sweeps weekly, so a
# `cat .env` in one session is not still sitting in the log next month.
{
  flake.modules.homeManager.transcript-sweep = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.transcripts.enable {
      home.packages = [pkgs.transcript-sweep];

      # Nightly is more than the leak rate needs, and the pass reads every
      # transcript in full, so it is weekly and idle. `plan` is not what runs
      # here: a timer that finds the secret and leaves it is only a report.
      systemd.user.services.transcript-sweep = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Replace secrets in agent transcripts";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.transcript-sweep} apply --quiet";
          Nice = 10;
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
        };
      };

      systemd.user.timers.transcript-sweep = lib.mkIf pkgs.stdenv.isLinux {
        Unit.Description = "Replace secrets in agent transcripts";
        Timer = {
          OnCalendar = config.fireproof.transcripts.schedule;
          Persistent = true;
          RandomizedDelaySec = "20min";
        };
        Install.WantedBy = ["timers.target"];
      };
    };
  };
}
