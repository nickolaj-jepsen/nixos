{
  flake.modules.homeManager.dms-plugins = {
    config,
    lib,
    pkgs,
    inputs,
    ...
  }: {
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
            variants =
              [
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
              ]
              ++ lib.optional config.fireproof.work.enable {
                id = "variant_tailnet";
                name = "Tailnet";
                icon = "lan";
                displayText = "";
                displayCommand = "tailnet";
                clickCommand = "tailnet toggle";
                middleClickCommand = "";
                rightClickCommand = "tailnet link";
                updateInterval = 5;
                showIcon = true;
                showText = true;
                visibilityCommand = "";
                visibilityInterval = 0;
              };
          };
        };
      };
    };
  };
}
