{
  config,
  lib,
  inputs,
  pkgsUnstable,
  ...
}: {
  imports = [
    ./theme.nix
    ./background.nix
    ./bar.nix
    ./plugins.nix
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
        enableVPN = false;
        enableCalendarEvents = false;
        dgop.package = pkgsUnstable.dgop; # not available in stable nixpkgs yet (25.11)

        systemd.enable = true;

        settings = {
          # General Settings
          weatherCoordinates = "56.1496278,10.2134046";

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
