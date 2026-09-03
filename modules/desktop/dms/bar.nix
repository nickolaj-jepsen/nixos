{
  flake.modules.homeManager.dms-bar = {
    config,
    lib,
    pkgs,
    fpLib,
    ...
  }: let
    inherit (config.fireproof) monitors;

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

    primaryMonitor = fpLib.primaryMonitor monitors;
    primaryX = primaryMonitor.position.x or 0;

    # Partition secondary monitors into left and right by x position relative to primary
    secondaryMonitors = fpLib.secondaryMonitors monitors;
    leftMonitors = builtins.filter (m: m.position.x <= primaryX) secondaryMonitors;
    rightMonitors = builtins.filter (m: m.position.x > primaryX) secondaryMonitors;

    primaryBar =
      commonBarSettings
      // {
        id = "default";
        name = "Primary Bar";

        # Primary sits flush against the screen edge, so it gets a slightly roomier,
        # rounded treatment; the secondaries keep the flat square defaults above.
        attachToScreenEdge = true;
        squareCorners = false;
        innerPadding = 0;
        widgetPadding = 12;
        barInsetPadding = 4;
        fontScale = 1.05;
        # Ignored while attachToScreenEdge is set (DMS forces 0); kept for when it isn't.
        spacing = 2;

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
          "dankActions:variant_ndw"
          "runningApps"
        ];
        centerWidgets = [
          "focusedWindow"
        ];
        rightWidgets =
          ["music"]
          ++ lib.optional config.fireproof.work.enable "dankActions:variant_tailnet"
          ++ [
            "systemTray"
            "cpuUsage"
            "diskUsage"
            "controlCenterButton"
          ]
          ++ lib.optional config.fireproof.hardware.battery "battery"
          ++ ["notificationButton"];
      };

    leftSecondaryBar =
      commonBarSettings
      // {
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
      };

    rightSecondaryBar =
      commonBarSettings
      // {
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
      };

    # Only include secondary bars if they have monitors assigned
    secondaryBars =
      (lib.optional (leftMonitors != []) leftSecondaryBar)
      ++ (lib.optional (rightMonitors != []) rightSecondaryBar);
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell.settings = {
        launcherStyle = "spotlight";
        launcherLogoMode = "os";
        launcherLogoContrast = 1;

        # Bar draws its own background; the global drop shadow just muddies the edge.
        barElevationEnabled = false;

        centeringMode = "geometric";

        runningAppsCurrentWorkspace = true;
        runningAppsGroupByApp = true;

        barConfigs = [primaryBar] ++ secondaryBars;
      };
    };
  };
}
