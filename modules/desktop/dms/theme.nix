{
  config,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
  c = config.fireproof.theme.colors;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      home.file.".config/DankMaterialShell/colors.json".text = builtins.toJSON {
        name = "custom";
        primary = "#${c.accent}";
        primaryText = "#${c.whiteAlt}";
        primaryContainer = "#${c.uiAlt}";
        secondary = "#${c.magenta}";
        surface = "#${c.ui}";
        surfaceText = "#${c.fg}";
        surfaceVariant = "#${c.bg}";
        surfaceVariantText = "#${c.fgAlt}";
        surfaceTint = "#${c.accent}";
        background = "#${c.black}";
        backgroundText = "#${c.whiteAlt}";
        outline = "#${c.muted}";
        surfaceContainer = "#${c.bg}";
        surfaceContainerHigh = "#${c.bgAlt}";
        surfaceContainerHighest = "#${c.uiAlt}";
        error = "#${c.red}";
        warning = "#${c.yellow}";
        info = "#${c.blue}";
        matugen_type = "scheme-expressive";
      };

      programs.dank-material-shell.settings = {
        # Color theme
        currentThemeName = "custom";
        customThemeFile = "/home/${username}/.config/DankMaterialShell/colors.json";
        widgetBackgroundColor = "sth";
        widgetColorMode = "default";

        # General
        cornerRadius = 8;

        # Font
        fontFamily = "Inter Variable";
        monoFontFamily = "Hack Nerd Font Mono";
        fontWeight = 400;
        fontScale = 1;
      };
    };
  };
}
