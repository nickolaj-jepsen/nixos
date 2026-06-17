{
  flake.modules.nixos.smartd = _: {
    config = {
      # Monitor all autodetected drives so degrading SMART attributes
      # (reallocated/pending sectors, SSD media-wearout, UDMA CRC errors)
      # raise an early warning before a disk actually fails.
      # Short self-test nightly @02:00, long self-test weekly Sun @03:00.
      # No MTA on these hosts, so notifications fall back to wall + journal.
      services.smartd = {
        enable = true;
        autodetect = true;
        defaults.monitored = "-a -o on -S on -s (S/../.././02|L/../../7/03)";
      };
    };
  };
}
