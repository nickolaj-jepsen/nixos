{
  config,
  lib,
  ...
}: let
  hasMonitors = config.monitors != [];

  commonBarSettings = {
    enabled = true;
    position = 0;

    spacing = 0;
    innerPadding = -4;
    bottomGap = -9;
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

  primaryMonitor =
    if hasMonitors
    then builtins.head config.monitors
    else {};
  primaryX = primaryMonitor.position.x or 0;

  # Partition secondary monitors into left and right based on their x position relative to primary
  secondaryMonitors =
    if hasMonitors
    then builtins.tail config.monitors
    else [];
  leftMonitors = builtins.filter (m: (m.position.x or 0) <= primaryX) secondaryMonitors;
  rightMonitors = builtins.filter (m: (m.position.x or 0) > primaryX) secondaryMonitors;

  primaryBar =
    {
      id = "default";
      name = "Primary Bar";
      screenPreferences = [
        {
          name = primaryMonitor.name or "";
        }
      ];
      showOnLastDisplay = true;
      leftWidgets = [
        "launcherButton"
        "clock"
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
      ];
    }
    // commonBarSettings;

  leftSecondaryBar =
    {
      id = "secondary-left";
      name = "Secondary Bar (Left)";
      screenPreferences =
        builtins.map (monitor: {
          inherit (monitor) name;
        })
        leftMonitors;
      showOnLastDisplay = false;
      leftWidgets = [];
      centerWidgets = [];
      rightWidgets = [
        "workspaceSwitcher"
      ];
    }
    // commonBarSettings;

  rightSecondaryBar =
    {
      id = "secondary-right";
      name = "Secondary Bar (Right)";
      screenPreferences =
        builtins.map (monitor: {
          inherit (monitor) name;
        })
        rightMonitors;
      showOnLastDisplay = false;
      leftWidgets = [
        "workspaceSwitcher"
      ];
      centerWidgets = [];
      rightWidgets = [];
    }
    // commonBarSettings;

  # Only include secondary bars if they have monitors assigned
  secondaryBars =
    (lib.optional (leftMonitors != []) leftSecondaryBar)
    ++ (lib.optional (rightMonitors != []) rightSecondaryBar);
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      programs.dankMaterialShell.default.settings = {
        launcherLogoMode = "os";
        launcherLogoContrast = 1;
        launcherLogoSizeOffset = 3;

        centeringMode = "geometric";

        runningAppsCurrentWorkspace = true;
        runningAppsGroupByApp = true;

        barConfigs = [primaryBar] ++ secondaryBars;
      };
    };
  };
}
