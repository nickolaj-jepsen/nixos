{
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
    # DMS derives its bar thickness internally (no settable key); hand-tuned to match.
    barHeight = 34;

    # Filter null resolutions (schema allows null) — would abort evaluation otherwise.
    positionableMonitors =
      builtins.filter (m: m.enable && m.resolution.width != null) monitors;

    # x in logical pixels (physical / scale) to match how DMS clamps the saved coord.
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
    config = lib.mkIf (config.fireproof.desktop.enable && primaryMonitor != {}) {
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
