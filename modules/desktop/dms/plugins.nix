{
  config,
  lib,
  inputs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      imports = [
        inputs.dms-plugin-registry.modules.default
      ];
      programs.dank-material-shell.plugins = {
        emojiLauncher = {
          enable = true;
          settings = {
            enabled = true;
          };
        };
        dankActions = {
          enable = true;
          settings = {
            enabled = true;
            variants = [
              {
                id = "variant_ndw";
                name = "Dynamic Workspaces";
                icon = "space_dashboard";
                displayText = "";
                displayCommand = "";
                clickCommand = "niri-dynamic-workspaces switch";
                middleClickCommand = "niri-dynamic-workspaces move-window";
                rightClickCommand = "niri-dynamic-workspaces delete";
                updateInterval = 0;
                showIcon = true;
                showText = false;
                visibilityCommand = "";
                visibilityInterval = 0;
              }
            ];
          };
        };
      };
    };
  };
}
