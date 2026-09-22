{
  flake.modules.nixos.battery = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.battery {
      services.upower.enable = true;
      # Backend for DMS's power-profile switch.
      services.power-profiles-daemon.enable = true;
    };
  };
}
