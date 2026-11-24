{
  flake.modules.nixos.oomd = {
    config,
    lib,
    ...
  }: let
    # Matched whole against /proc/<pid>/comm, which is cut to 15 characters.
    names = list: "^(${lib.concatMapStringsSep "|" lib.escapeRegex list})$";
  in {
    config = lib.mkMerge [
      # Kill the worst cgroup under system.slice on sustained pressure. zram otherwise keeps the
      # kernel OOM killer from firing for hours while every service stalls.
      (lib.mkIf config.fireproof.homelab.enable {
        systemd.oomd.enableSystemSlice = true;
      })
      (lib.mkIf config.fireproof.desktop.enable {
        # oomd runs by default but monitors nothing. Watch only the user manager's app/background
        # slices (niri scopes launched apps there) so a runaway app is killed before the session
        # thrashes, while niri/dms in session.slice are never candidates. oomd kills a whole leaf
        # cgroup, an app or a terminal with the agent and tools in it, so it is the last resort;
        # earlyoom below goes first, one process at a time.
        systemd.user.slices = lib.genAttrs ["app" "background"] (_: {
          overrideStrategy = "asDropin";
          sliceConfig = {
            ManagedOOMMemoryPressure = "kill";
            ManagedOOMMemoryPressureLimit = "80%";
          };
        });

        # A full zram is the distress signal: reclaim can then only drop file pages, programs'
        # code included, and the desktop thrashes with a fifth of RAM still "available". So act
        # when both are short: SIGTERM below 25% available and 5% free swap, SIGKILL at half.
        # earlyoom's total is RAM minus what zram holds, so the thrash it must catch read ~22%.
        services.earlyoom = {
          enable = true;
          freeMemThreshold = 25;
          freeSwapThreshold = 5;
          enableNotifications = true;
          extraArgs = [
            # Run at nice -20, so it still gets CPU while the machine thrashes.
            "-p"
            # The victim is a build or test worker, never the session or an agent itself.
            "--prefer"
            (names ["cc1" "cc1plus" "rustc" "clang" "ld" "ld.lld" "mold" "tsc" "tsgo" "MainThread"])
            "--avoid"
            (names [
              "niri"
              "niri-session"
              # umbriel's binary is wrapped; comm is cut at 15 characters.
              ".umbriel-wrappe"
              "start-umbriel"
              ".dms-wrapped"
              "Xwayland"
              ".xwayland-satel"
              "pipewire"
              "pipewire-pulse"
              "wireplumber"
              "keyd"
              ".zed-editor-wra"
              ".firefox-wrappe"
              "kitty"
              "claude"
              ".claude-wrapped"
              "claude.exe"
              "pi"
              "codex"
            ])
          ];
        };
      })
    ];
  };
}
