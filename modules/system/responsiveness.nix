{
  flake.modules.nixos.responsiveness = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # No sched_ext scheduler (scx_bpfland & co.): they ignore cgroup CPU weights, which is what
      # keeps niri in session.slice responsive while app.slice is saturated; under scx_bpfland a
      # single parallel build made input lag. The kernel's EEVDF honours them.
      # Give the session a bigger share than stock: under 32 CPU hogs it halved niri's worst wait.
      systemd.user.slices.session = lib.mkIf config.fireproof.desktop.enable {
        overrideStrategy = "asDropin";
        sliceConfig.CPUWeight = 1000;
      };
      # Daemons nobody waits on (agent-hub, llama-swap, devmon) yield to the apps under load.
      systemd.user.slices.background = lib.mkIf config.fireproof.desktop.enable {
        overrideStrategy = "asDropin";
        sliceConfig.CPUWeight = 20;
      };
      # Firefox outranks the rest of app.slice: inside it CPU is otherwise shared per thread, so a
      # dozen busy agent terminals left it ~1 of 16 cores. With this it kept ~90% of what it asked
      # for beside 32 CPU hogs. A weight on any app scope also makes app.slice share per app.
      # Prefix drop-ins match the launchers' transient scopes (app-dms-firefox-<id>.scope).
      systemd.user.units = lib.mkIf config.fireproof.desktop.enable (lib.genAttrs [
          "app-dms-firefox-.scope"
          "app-niri-firefox-.scope"
        ] (_: {
          overrideStrategy = "asDropin";
          text = ''
            [Scope]
            CPUWeight=1000
          '';
        }));

      # Gauges for scheduling delay: runqlat/runqslower (bcc), bpftrace, perf.
      programs.bcc.enable = true;
      environment.systemPackages = [pkgs.bpftrace pkgs.perf];

      # mq-deadline ignores cgroup IOWeight; BFQ makes nix.slice's weight real.
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
