{inputs, ...}: {
  flake.modules.homeManager.dms-plugins = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # With the Hyprland session on, a wrapper opens the picker of whichever session is running.
    projects = action: niriAction:
      if config.fireproof.desktop.hyprland.enable
      then "project-workspaces ${action}"
      else "niri-dynamic-workspaces ${niriAction}";
  in {
    imports = [
      inputs.dms-plugin-registry.nixosModules.default
    ];
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
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
                clickCommand = projects "switch" "switch";
                middleClickCommand = projects "move" "move-window";
                rightClickCommand = projects "close" "delete";
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
