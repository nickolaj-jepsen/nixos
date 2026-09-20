# Headless: nobody is at the console to answer an emergency shell or power-cycle a hang.
{
  flake.modules.nixos.homelab-resilience = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      # Root has no password: the emergency shell is a dead end that keeps sshd from starting.
      systemd.enableEmergencyMode = false;

      systemd.settings.Manager = {
        RuntimeWatchdogSec = "30s";
        RebootWatchdogSec = "10min";
      };
      boot.kernel.sysctl."kernel.panic" = 10; # seconds until reboot
    };
  };
}
