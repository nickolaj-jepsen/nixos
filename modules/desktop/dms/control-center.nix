{
  flake.modules.homeManager.dms-control-center = {
    config,
    lib,
    ...
  }: {
    config.programs.dank-material-shell.settings = {
      controlCenterWidgets =
        [
          {
            id = "volumeSlider";
            enabled = true;
            width =
              if config.fireproof.hardware.dimmableBacklight
              then 50
              else 100;
          }
        ]
        ++ lib.optionals config.fireproof.hardware.dimmableBacklight [
          {
            id = "brightnessSlider";
            enabled = true;
            width = 50;
          }
        ]
        ++ [
          {
            id = "audioOutput";
            enabled = true;
            width = 50;
          }
          {
            id = "audioInput";
            enabled = true;
            width = 50;
          }
        ]
        ++ lib.optionals config.fireproof.hardware.wifi [
          {
            id = "wifi";
            enabled = true;
            width = 50;
          }
        ]
        ++ [
          {
            id = "bluetooth";
            enabled = true;
            width =
              if config.fireproof.hardware.wifi
              then 50
              else 100;
          }
          {
            id = "builtin_vpn";
            enabled = true;
            width = 50;
          }
          {
            id = "builtin_cups";
            enabled = true;
            width = 50;
          }
        ]
        ++ lib.optionals config.fireproof.hardware.battery [
          {
            id = "battery";
            enabled = true;
            width = 100;
          }
        ]
        # Restore the stock quick toggles dropped by overriding the default list.
        # darkMode works everywhere. nightMode drives DMS's own gamma engine over
        # wlr-gamma-control (which niri implements) — it is NOT a no-op. If it
        # ever fails to tint, suspect NVIDIA multi-monitor gamma quirks (DMS
        # issues #924/#2197), not a missing backend; do not add wlsunset/gammastep.
        # Also bound to Mod+Shift+B in niri/binds.nix.
        ++ [
          {
            id = "darkMode";
            enabled = true;
            width = 50;
          }
          {
            id = "nightMode";
            enabled = true;
            width = 50;
          }
        ];
    };
  };
}
