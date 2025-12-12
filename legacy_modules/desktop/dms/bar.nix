{config, ...}: let
  commonBarSettings = {
    enabled = true;
    position = 0;

    spacing = 0;
    innerPadding = 0;
    bottomGap = -5;
    transparency = 0;
    widgetTransparency = 1;
    squareCorners = true;
    noBackground = false;
    gothCornersEnabled = false;
    gothCornerRadiusOverride = false;
    gothCornerRadiusValue = 12;
    borderEnabled = false;
    borderColor = "primary";
    borderOpacity = 1;
    borderThickness = 2;
    widgetOutlineEnabled = false;
    widgetOutlineColor = "primary";
    widgetOutlineOpacity = 1;
    widgetOutlineThickness = 1;
    fontScale = 1;
    autoHide = false;
    autoHideDelay = 250;
    openOnOverview = false;
    visible = true;
    popupGapsAuto = true;
    popupGapsManual = 4;
    maximizeDetection = true;
  };
  primaryBar =
    {
      id = "default";
      name = "Primary Bar";
      screenPreferences = [
        {
          name = (builtins.head config.monitors).name or "";
        }
      ];
      showOnLastDisplay = true;
      leftWidgets = [
        "launcherButton"
        "workspaceSwitcher"
        "runningApps"
      ];
      centerWidgets = [
        "focusedWindow"
      ];
      rightWidgets = [
        "music"
        "systemTray"
        "cpuUsage"
        "controlCenterButton"
        "notificationButton"
        "clock"
      ];
    }
    // commonBarSettings;
  secondaryBar =
    {
      id = "secondary";
      name = "Secondary Bar";
      screenPreferences = builtins.map (monitor: {
        inherit (monitor) name;
      }) (builtins.tail config.monitors);
      showOnLastDisplay = false;
      leftWidgets = [
        "workspaceSwitcher"
      ];
      centerWidgets = [];
      rightWidgets = [];
    }
    // commonBarSettings;
in {
  fireproof.home-manager = {
    programs.dankMaterialShell.default.settings = {
      launcherLogoMode = "os";
      launcherLogoContrast = 1;
      launcherLogoSizeOffset = 3;

      centeringMode = "geometric";

      runningAppsCurrentWorkspace = true;
      runningAppsGroupByApp = true;

      barConfigs = [primaryBar secondaryBar];
    };
  };
}
