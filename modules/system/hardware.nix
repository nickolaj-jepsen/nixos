{
  flake.modules.nixos.hardware = {
    config,
    lib,
    ...
  }: let
    inherit (config.fireproof.hardware) physical;
  in {
    # No firmware to load or flash under WSL; linux-firmware alone is ~800 MB of closure.
    services.fwupd.enable = physical;
    hardware.enableRedistributableFirmware = physical;

    # fwupd orders itself Before=display-manager, so the hourly timer's catch-up run at boot
    # held the greeter behind network-online + fwupd startup (~5 s).
    systemd.timers = lib.mkIf physical {
      fwupd-refresh.timerConfig.Persistent = false;
    };

    # Periodic TRIM for SSDs (weekly). Harmless without an SSD; on WSL it lets a sparse VHD shrink.
    services.fstrim.enable = true;
  };
}
