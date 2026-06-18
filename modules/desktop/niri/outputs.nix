{
  flake.modules.homeManager.niri-outputs = {
    config,
    lib,
    fpLib,
    ...
  }: let
    primaryMonitorName = fpLib.primaryMonitorName config.fireproof.monitors;
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      programs.niri.settings = {
        workspaces = lib.mkIf (primaryMonitorName != "") (
          lib.genAttrs ["01" "02" "03" "04" "05"] (_: {open-on-output = primaryMonitorName;})
        );

        outputs = lib.mkIf (config.fireproof.monitors != []) (
          lib.listToAttrs (map (monitor: {
              inherit (monitor) name;
              value = {
                inherit (monitor) position enable;
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
            config.fireproof.monitors)
        );
      };
    };
  };
}
