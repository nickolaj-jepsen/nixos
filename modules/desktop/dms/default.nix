{
  config,
  lib,
  inputs,
  pkgs,
  ...
}: {
  imports = [
    ./theme.nix
    ./control-center.nix
    ./background.nix
    ./bar.nix
    ./plugins.nix
    ./desktop-widgets.nix
  ];

  config = lib.mkIf config.fireproof.desktop.windowManager.enable {
    systemd.user.services.niri-flake-polkit.enable = false;

    fireproof.home-manager = {
      imports = [
        inputs.dank-material-shell.homeModules.dank-material-shell
      ];

      programs.dank-material-shell = {
        enable = true;

        enableDynamicTheming = false;
        enableVPN = true;
        enableCalendarEvents = false;
        dgop.package = pkgs.unstable.dgop; # not available in stable nixpkgs yet (26.05)
        quickshell.package = pkgs.unstable.quickshell; # dms 1.5-beta needs quickshell >= 0.3.0 for `pragma AppId`

        systemd.enable = true;

        # weatherCoordinates is a session.json key (moved out of settings.json in
        # the v5 migration), so it must live under `session`, not `settings`.
        # weatherEnabled defaults true, so this is all that's needed for weather.
        session.weatherCoordinates = "56.1496278,10.2134046";

        settings = {
          # Match the pinned DMS schema version (SettingsData.qml). Bumping from 5
          # avoids a per-start in-memory migration; note it also lets the bar's
          # shadow/elevation (barElevationEnabled, default true) take effect.
          configVersion = 11;

          # Lock Screen
          loginctlLockIntegration = true;
          fadeToLockEnabled = true;
          fadeToLockGracePeriod = 5;

          acMonitorTimeout = 1800;
          acLockTimeout = 600;
          acSuspendTimeout = 0;
          batteryMonitorTimeout = 600;
          batteryLockTimeout = 300;
          batterySuspendTimeout = 1800;

          # Power Menu
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
    };
  };
}
