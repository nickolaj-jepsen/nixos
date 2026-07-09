{
  flake.modules.nixos.dms = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      systemd.user.services.niri-flake-polkit.enable = false;
    };
  };

  flake.modules.homeManager.dms = {
    config,
    lib,
    inputs,
    pkgs,
    ...
  }: {
    imports = [
      inputs.dank-material-shell.homeModules.dank-material-shell
    ];
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell = {
        enable = true;

        enableDynamicTheming = false;
        enableVPN = true;
        enableCalendarEvents = false;
        dgop.package = pkgs.unstable.dgop; # not in stable nixpkgs (26.05) yet
        quickshell.package = pkgs.unstable.quickshell; # dms 1.5-beta needs quickshell >= 0.3.0 for `pragma AppId`

        systemd.enable = true;

        # weatherCoordinates is a session.json key, so it must live under `session`, not `settings`.
        session.weatherCoordinates = "56.1496278,10.2134046";

        settings = {
          # Must match SettingsData.qml schema version, else a per-start migration runs silently; re-pin after `just update`.
          configVersion = 12;

          # Enable blur on DMS's layer-shell surfaces. Blur only shows through
          # translucency, so popupTransparency must be < 1 — the default 1.0 is solid
          # and hides it entirely.
          blurEnabled = true;
          popupTransparency = 0.65;

          loginctlLockIntegration = true;
          fadeToLockEnabled = true;
          fadeToLockGracePeriod = 5;

          acMonitorTimeout = 1800;
          acLockTimeout = 600;
          acSuspendTimeout = 0;
          batteryMonitorTimeout = 600;
          batteryLockTimeout = 300;
          batterySuspendTimeout = 1800;

          powerMenuActions = [
            "reboot"
            "logout"
            "poweroff"
            "lock"
            "suspend"
          ];
          powerMenuDefaultAction = "lock";
        };
      };

      # niri defaults blur to xray (blurs the wallpaper — near-black here, so popouts
      # look solid); force xray off so DMS's layers blur the windows behind them.
      # niri-flake can't express background-effect, so append the rule and re-validate
      # against niri-unstable (its default niri-stable predates it, would reject it).
      xdg.configFile.niri-config.source = lib.mkForce (
        pkgs.runCommand "niri-config.kdl" {
          config =
            config.programs.niri.finalConfig
            + ''

              layer-rule {
                  match namespace="^dms:"
                  background-effect {
                      xray false
                  }
              }
            '';
          passAsFile = ["config"];
          buildInputs = [pkgs.niri-unstable];
        } ''
          niri validate -c $configPath
          cp $configPath $out
        ''
      );
    };
  };
}
