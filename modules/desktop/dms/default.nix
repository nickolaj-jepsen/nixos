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
        dgop.package = pkgs.unstable.dgop; # not available in stable nixpkgs yet (25.11)

        systemd.enable = true;

        settings = {
          configVersion = 5;

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
