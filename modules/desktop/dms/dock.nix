{
  flake.modules.homeManager.dms-dock = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell.settings = {
        showDock = true;

        # Reveal only when floating windows leave the dock area clear; mutually
        # exclusive with dockAutoHide (DMS unsets one when the other is set).
        dockSmartAutoHide = true;

        dockIsolateDisplays = true;
        dockGroupByApp = true;

        # 0 like the bars — lets blurEnabled show through instead of a solid fill.
        dockTransparency = 0;
        dockSpacing = 11;
        dockIndicatorStyle = "line";

        dockLauncherEnabled = true;
        dockLauncherLogoMode = "os";
      };
    };
  };
}
