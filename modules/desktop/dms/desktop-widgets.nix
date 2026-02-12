{
  config,
  lib,
  ...
}: let
  hasMonitors = config.monitors != [];

  primaryMonitor =
    if hasMonitors
    then builtins.head config.monitors
    else {};

  widgetWidth = 320;
  widgetHeight = 480;
  padding = 16;
  barHeight = 34;

  # Calculate top-right position for a given monitor, below the bar
  mkPosition = monitor: {
    width = widgetWidth;
    height = widgetHeight;
    x = monitor.resolution.width - widgetWidth - padding;
    y = barHeight + padding;
  };

  positions = lib.listToAttrs (map (monitor: {
      inherit (monitor) name;
      value = mkPosition monitor;
    })
    config.monitors);
in {
  config = lib.mkIf (config.fireproof.desktop.enable && hasMonitors) {
    fireproof.home-manager = {
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
              showGpuTemp = false;
              gpuPciId = "";
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
