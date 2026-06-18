{
  flake.modules.nixos.zram = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.zram {
      # Compressed RAM swap. None of these hosts have disk swap, which leaves
      # systemd-oomd's PSI-based handling degraded ("No swap; memory pressure
      # usage will be degraded"). zram restores it and gives a pressure-relief
      # valve, writing nothing to disk (important where the root SSD is full).
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
      };

      # Companion tuning the zramSwap module does not apply itself.
      boot.kernel.sysctl = {
        # zram is RAM-fast and random-access, so swap read-ahead only wastes CPU
        # decompressing pages that won't be used. Fault one page at a time.
        "vm.page-cluster" = 0;
        # Compressed-RAM swap is cheap, so prefer swapping anonymous pages over
        # evicting file cache. 180 is the modern zram value (kernel max is 200).
        "vm.swappiness" = 180;
      };
    };
  };
}
