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
    config = lib.mkIf config.fireproof.desktop.enable {
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
          configVersion = 11;

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
    };
  };
}
