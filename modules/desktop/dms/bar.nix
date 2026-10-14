{fpLib, ...}: {
  flake.modules.homeManager.dms-bar = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.fireproof) monitors;

    # Sub-keys of disabled features (border*, widgetOutline*, gothCorner*, autoHideDelay, popupGapsManual) are left out.
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
      borderEnabled = false;
      widgetOutlineEnabled = false;
      fontScale = 1;
      autoHide = false;
      openOnOverview = false;
      visible = true;
      popupGapsAuto = true;
      maximizeDetection = true;
    };

    primaryMonitor = fpLib.primaryMonitor monitors;
    primaryX = primaryMonitor.position.x or 0;
    secondaryMonitors = fpLib.secondaryMonitors monitors;

    primaryBar =
      commonBarSettings
      // {
        id = "default";
        name = "Primary Bar";

        # Primary sits flush against the screen edge, so it gets a roomier, rounded treatment.
        attachToScreenEdge = true;
        squareCorners = false;
        innerPadding = 0;
        widgetPadding = 12;
        barInsetPadding = 4;
        fontScale = 1.05;
        # Ignored while attachToScreenEdge is set (DMS forces 0); kept for when it isn't.
        spacing = 2;

        screenPreferences = [{name = primaryMonitor.name or "";}];
        showOnLastDisplay = true;
        leftWidgets = [
          "launcherButton"
          "clock"
          "workspaceSwitcher"
          "dankActions:variant_ndw"
          "runningApps"
        ];
        centerWidgets = ["focusedWindow"];
        rightWidgets =
          [
            "music"
            "systemTray"
            "cpuUsage"
            "diskUsage"
            "controlCenterButton"
          ]
          ++ lib.optional config.fireproof.hardware.battery "battery"
          ++ ["notificationButton"];
      };

    # One bar per side of the primary, with the workspace switcher on the edge facing it.
    secondaryBar = side: onSide: let
      screens = builtins.filter (m: onSide m.position.x) secondaryMonitors;
    in
      lib.optional (screens != []) (commonBarSettings
        // {
          id = "secondary-${lib.toLower side}";
          name = "Secondary Bar (${side})";
          screenPreferences = map (m: {inherit (m) name;}) screens;
          showOnLastDisplay = false;
          leftWidgets = lib.optional (side == "Right") "workspaceSwitcher";
          centerWidgets = [];
          rightWidgets = lib.optional (side == "Left") "workspaceSwitcher";
        });
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

        barConfigs = [primaryBar] ++ secondaryBar "Left" (x: x <= primaryX) ++ secondaryBar "Right" (x: x > primaryX);
      };
    };
  };
}
