{
  flake.modules.nixos.smartd = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # No MTA on these hosts; wall alone reaches no one on a Wayland desktop, so warnings also
      # go out as desktop notifications (systembus-notify is inert without a graphical session).
      services.smartd = {
        enable = true;
        autodetect = true;
        notifications.systembus-notify.enable = true;
        # -s schedule: Short self-test daily @02:00, Long self-test Sundays @03:00.
        defaults.monitored = "-a -o on -S on -s (S/../.././02|L/../../7/03)";
      };
    };
  };
}
