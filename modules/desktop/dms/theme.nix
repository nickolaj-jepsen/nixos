{
  flake.modules.homeManager.dms-theme = {
    config,
    lib,
    ...
  }: let
    inherit (config.fireproof) username;
    c = config.fireproof.theme.colors;
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.file.".config/DankMaterialShell/colors.json".text = builtins.toJSON {
        name = "custom";
        primary = "#${c.accent}";
        primaryText = "#${c.whiteAlt}";
        # coral container so selection reads as a tonal sibling of primary, not neutral gray
        primaryContainer = "#${c.accentContainer}";
        secondary = "#${c.magenta}";
        # surfaceVariant is the lightest tone so hover/pressed states lighten rather than darken
        background = "#${c.black}";
        backgroundText = "#${c.whiteAlt}";
        surface = "#${c.bg}";
        surfaceText = "#${c.fg}";
        surfaceContainer = "#${c.bgAlt}";
        surfaceContainerHigh = "#${c.ui}";
        surfaceContainerHighest = "#${c.uiAlt}";
        surfaceVariant = "#${c.uiAlt}";
        surfaceVariantText = "#${c.fgAlt}";
        surfaceTint = "#${c.accent}";
        outline = "#${c.muted}";
        error = "#${c.red}";
        warning = "#${c.yellow}";
        info = "#${c.blue}";
        success = "#${c.green}";
        # matugen_type omitted: dead key with dynamic theming off / fixed palette
      };

      programs.dank-material-shell.settings = {
        currentThemeName = "custom";
        customThemeFile = "/home/${username}/.config/DankMaterialShell/colors.json";
        widgetColorMode = "default";

        # colors.json is dark-only; a portal light/dark flip would mislabel the dark colors as "light"
        syncModeWithPortal = false;

        cornerRadius = 8;

        fontFamily = "Inter Variable";
        monoFontFamily = "Hack Nerd Font Mono";
        fontWeight = 400;
        fontScale = 1;
      };
    };
  };
}
