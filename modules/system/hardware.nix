_: {
  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Periodic TRIM for SSDs (weekly). Harmless on hosts without SSDs.
  services.fstrim.enable = true;
}
