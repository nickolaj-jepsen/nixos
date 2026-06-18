{
  flake.modules.nixos.zram = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.zram {
      # No disk swap on these hosts; zram restores oomd's PSI handling without writing to the (often full) SSD.
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
      };

      boot.kernel.sysctl = {
        # zram is random-access, so swap read-ahead only wastes CPU; fault one page at a time.
        "vm.page-cluster" = 0;
        # High swappiness (180; kernel max 200): zram swap is cheap, so prefer swapping anon pages to evicting file cache.
        "vm.swappiness" = 180;
      };
    };
  };
}
