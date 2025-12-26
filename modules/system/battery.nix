{
  config,
  lib,
  ...
}: {
  config = lib.mkIf config.fireproof.hardware.battery {
    services.upower.enable = true;
  };
}
