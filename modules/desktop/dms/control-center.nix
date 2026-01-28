{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.desktop.enable {
  fireproof.home-manager = {
    programs.dank-material-shell.settings = {
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
        ];
    };
  };
}
