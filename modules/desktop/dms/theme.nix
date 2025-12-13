{
  config,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      home.file.".config/DankMaterialShell/colors.json".text = builtins.toJSON {
        name = "custom";
        primary = "#CF6A4C";
        primaryText = "#F2F0E5";
        primaryContainer = "#403E3C";
        secondary = "#CE5D97";
        surface = "#343331";
        surfaceText = "#DAD8CE";
        surfaceVariant = "#1C1B1A";
        surfaceVariantText = "#B7B5AC";
        surfaceTint = "#CF6A4C";
        background = "#100F0F";
        backgroundText = "#F2F0E5";
        outline = "#878580";
        surfaceContainer = "#1C1B1A";
        surfaceContainerHigh = "#282726";
        surfaceContainerHighest = "#403E3C";
        error = "#D14D41";
        warning = "#D0A215";
        info = "#4385BE";
        matugen_type = "scheme-expressive";
      };

      programs.dankMaterialShell.default.settings = {
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
