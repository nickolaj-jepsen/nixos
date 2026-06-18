{
  flake.modules.nixos.smartd = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # No MTA on these hosts, so notifications fall back to wall + journal.
      services.smartd = {
        enable = true;
        autodetect = true;
        # -s schedule: Short self-test daily @02:00, Long self-test Sundays @03:00.
        defaults.monitored = "-a -o on -S on -s (S/../.././02|L/../../7/03)";
      };
    };
  };
}
