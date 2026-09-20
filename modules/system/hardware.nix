{
  flake.modules.nixos.hardware = {config, ...}: let
    inherit (config.fireproof.hardware) physical;
  in {
    # No firmware to load or flash under WSL; linux-firmware alone is ~800 MB of closure.
    services.fwupd.enable = physical;
    hardware.enableRedistributableFirmware = physical;

    # Periodic TRIM for SSDs (weekly). Harmless without an SSD; on WSL it lets a sparse VHD shrink.
    services.fstrim.enable = true;
  };
}
