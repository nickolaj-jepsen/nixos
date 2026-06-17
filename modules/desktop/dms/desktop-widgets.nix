# Aspect: desktop
{
  flake.aspectTags.dms-desktop-widgets = ["desktop"];

  flake.modules.homeManager.dms-desktop-widgets = {
    config,
    lib,
    fpLib,
    ...
  }: let
    inherit (config.fireproof) monitors;
    primaryMonitor = fpLib.primaryMonitor monitors;
    gpuPciId = config.fireproof.hardware.gpuPciId;

    widgetWidth = 320;
    widgetHeight = 480;
    padding = 16;
    # Hand-tuned approximation of DMS's dynamic top-bar thickness. DMS computes the
    # bar height internally (effectiveBarThickness in DankBarWindow.qml) from
    # Theme.barHeight, widgetThickness and innerPadding — there is no settable
    # bar-height key to derive this from. For this config it works out to ~32px.
    barHeight = 34;

    # Only place the widget on active monitors that declare a resolution (the
    # schema allows a null resolution, which would abort evaluation otherwise).
    positionableMonitors =
      builtins.filter (m: m.enable && m.resolution.width != null) monitors;

    # Top-right position, below the bar. x is in logical pixels (physical width
    # divided by scale) to match how DMS clamps the saved coordinate.
    mkPosition = monitor: {
      width = widgetWidth;
      height = widgetHeight;
      x = (builtins.floor (monitor.resolution.width / monitor.scale)) - widgetWidth - padding;
      y = barHeight + padding;
    };

    positions = lib.listToAttrs (map (monitor: {
        inherit (monitor) name;
        value = mkPosition monitor;
      })
      positionableMonitors);
  in {
    config = lib.mkIf (primaryMonitor != {}) {
      programs.dank-material-shell.settings = {
        desktopWidgetInstances = [
          {
            id = "dw_system_monitor";
            widgetType = "systemMonitor";
            name = "System Monitor";
            enabled = true;
            config = {
              showHeader = true;
              transparency = 0;
              colorMode = "primary";
              customColor = "#ffffff";
              showCpu = true;
              showCpuGraph = true;
              showCpuTemp = true;
              # GPU temp needs a non-empty pciId — there is no first-GPU fallback.
              showGpuTemp = gpuPciId != null;
              gpuPciId =
                if gpuPciId != null
                then gpuPciId
                else "";
              showMemory = true;
              showMemoryGraph = true;
              showNetwork = true;
              showNetworkGraph = true;
              showDisk = true;
              showTopProcesses = true;
              topProcessCount = 10;
              topProcessSortBy = "cpu";
              layoutMode = "list";
              graphInterval = 300;
              displayPreferences = [
                (primaryMonitor.name or "")
              ];
              showOnOverlay = false;
              syncPositionAcrossScreens = false;
            };
            inherit positions;
          }
        ];
      };
    };
  };
}
