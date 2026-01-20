{
  config,
  lib,
  ...
}: let
  hasMonitors = config.monitors != [];
  primaryMonitorName =
    if hasMonitors
    then (builtins.head config.monitors).name or ""
    else "";
in {
  config = lib.mkIf config.fireproof.desktop.windowManager.enable {
    fireproof.home-manager.programs.niri.settings = {
      workspaces = lib.mkIf (primaryMonitorName != "") {
        "01".open-on-output = primaryMonitorName;
        "02".open-on-output = primaryMonitorName;
        "03".open-on-output = primaryMonitorName;
        "04".open-on-output = primaryMonitorName;
        "05".open-on-output = primaryMonitorName;
      };

      outputs = lib.mkIf (config.monitors != []) (
        lib.listToAttrs (map (monitor: {
            inherit (monitor) name;
            value = {
              inherit (monitor) position;
              mode = lib.mkIf (monitor.resolution.width != null && monitor.resolution.height != null) {
                inherit (monitor.resolution) width height;
                refresh = monitor.refreshRateNiri;
              };
              focus-at-startup = monitor.name == primaryMonitorName;
              transform.rotation =
                if (monitor.transform != null)
                then monitor.transform * 90
                else 0;
            };
          })
          config.monitors)
      );
    };
  };
}
