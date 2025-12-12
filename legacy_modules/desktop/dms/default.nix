{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    ./theme.nix
    ./background.nix
    ./bar.nix
  ];

  systemd.user.services.niri-flake-polkit.enable = false;

  fireproof.home-manager = {
    imports = [
      inputs.dankMaterialShell.homeModules.dankMaterialShell.default
    ];

    programs.dankMaterialShell = {
      enable = true;

      enableDynamicTheming = false;
      enableClipboard = false;
      enableVPN = false;
      enableCalendarEvents = false;

      default.settings = {
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

    systemd.user.services = {
      # A hack to always serve fresh settings from default-settings.json
      dms-clean-settings = {
        Unit = {
          Description = "Delete DankMaterialShell settings before dms starts";
          Before = ["dms.service"];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/rm -f %h/.config/DankMaterialShell/settings.json";
        };
        Install.WantedBy = ["dms.service"];
      };
    };
  };
}
