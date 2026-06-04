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
        # Coral-tinted container (was neutral gray uiAlt) so selection highlights
        # and text-field selection read as a tonal sibling of primary.
        primaryContainer = "#${c.accentContainer}";
        secondary = "#${c.magenta}";
        # Surface tiers, ascending luminance (Material-3 lighten-on-elevation):
        #   background < surface < container < containerHigh < containerHighest.
        # surfaceVariant is the lightest tone so derived hover/pressed states
        # lighten the surface they overlay rather than darkening it.
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
        matugen_type = "scheme-expressive";
      };

      programs.dank-material-shell.settings = {
        # Color theme
        currentThemeName = "custom";
        customThemeFile = "/home/${username}/.config/DankMaterialShell/colors.json";
        widgetBackgroundColor = "sth";
        widgetColorMode = "default";

        # Stay dark regardless of the desktop portal's light/dark preference;
        # colors.json only defines a dark palette, so a portal flip would
        # otherwise render the dark colors in "light" mode.
        syncModeWithPortal = false;

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
