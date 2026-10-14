{
  flake.modules.nixos.oomd = {
    config,
    lib,
    ...
  }: {
    config = lib.mkMerge [
      # Kill the worst cgroup under system.slice on sustained pressure. zram otherwise keeps the
      # kernel OOM killer from firing for hours while every service stalls.
      (lib.mkIf config.fireproof.homelab.enable {
        systemd.oomd.enableSystemSlice = true;
      })
      (lib.mkIf config.fireproof.desktop.enable {
        # oomd runs by default but monitors nothing. Watch only the user manager's app/background
        # slices (niri scopes launched apps there) so a runaway app is killed before the session
        # thrashes, while niri/dms in session.slice are never candidates. Pressure-based only: with
        # zram as the only swap, swap usage is not a distress signal.
        systemd.user.slices = lib.genAttrs ["app" "background"] (_: {
          overrideStrategy = "asDropin";
          sliceConfig = {
            ManagedOOMMemoryPressure = "kill";
            ManagedOOMMemoryPressureLimit = "80%";
          };
        });
      })
    ];
  };
}
