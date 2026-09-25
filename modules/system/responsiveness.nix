{
  flake.modules.nixos.responsiveness = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # Ranks frequent sleepers ahead of CPU hogs, so every compiler yields to the desktop without per-tool rules.
      services.scx = lib.mkIf config.fireproof.desktop.enable {
        enable = true;
        scheduler = "scx_bpfland";
      };

      # mq-deadline ignores cgroup IOWeight; BFQ makes the nix-build slice's weight real.
      boot.kernelModules = ["bfq"];
      services.udev.extraRules = ''
        ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="bfq"
      '';

      boot.kernel.sysctl = {
        # The 20%/10%-of-RAM defaults let GBs of dirty pages pile up, then every fsync() stalls behind the flush.
        "vm.dirty_bytes" = 268435456;
        "vm.dirty_background_bytes" = 67108864;
        # Proactive compaction migrates pages under running apps (stalls in migration_entry_wait).
        "vm.compaction_proactiveness" = 0;
        # Wake kswapd earlier so allocations rarely fall into direct reclaim.
        "vm.watermark_scale_factor" = 125;
      };
    };
  };
}
