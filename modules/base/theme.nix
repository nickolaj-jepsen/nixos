# Flexoki-inspired (https://stephango.com/flexoki); emitted to both classes so HM can read colors without an osConfig bridge.
let
  themeOptions = {lib, ...}: let
    mkColorOption = default: description:
      lib.mkOption {
        type = lib.types.str;
        inherit default description;
        example = default;
      };
  in {
    options.fireproof.theme.colors = {
      bg = mkColorOption "1C1B1A" "Primary background color";
      bgAlt = mkColorOption "282726" "Alternative background color";

      fg = mkColorOption "DAD8CE" "Primary foreground/text color";
      fgAlt = mkColorOption "B7B5AC" "Alternative foreground color";

      muted = mkColorOption "878580" "Muted/disabled text color";
      ui = mkColorOption "343331" "UI element background";
      uiAlt = mkColorOption "403E3C" "Alternative UI element background";

      black = mkColorOption "100F0F" "Black (darkest)";
      white = mkColorOption "DAD8CE" "White (same as fg)";
      whiteAlt = mkColorOption "F2F0E5" "Bright white";

      accent = mkColorOption "CF6A4C" "Primary accent color";
      accentContainer = mkColorOption "6B3528" "Dark container tone derived from accent";

      red = mkColorOption "D14D41" "Red (errors, destructive)";
      redAlt = mkColorOption "AF3029" "Dark red";
      orange = mkColorOption "DA702C" "Orange (warnings)";
      orangeAlt = mkColorOption "BC5215" "Dark orange";
      yellow = mkColorOption "D0A215" "Yellow (caution)";
      yellowAlt = mkColorOption "AD8301" "Dark yellow";
      green = mkColorOption "879A39" "Green (success)";
      greenAlt = mkColorOption "66800B" "Dark green";
      cyan = mkColorOption "3AA99F" "Cyan";
      cyanAlt = mkColorOption "24837B" "Dark cyan";
      blue = mkColorOption "4385BE" "Blue (info, links)";
      blueAlt = mkColorOption "205EA6" "Dark blue";
      purple = mkColorOption "8B7EC8" "Purple";
      purpleAlt = mkColorOption "5E409D" "Dark purple";
      magenta = mkColorOption "CE5D97" "Magenta";
      magentaAlt = mkColorOption "A02F6F" "Dark magenta";
    };
  };
in {
  flake.modules.nixos.theme = themeOptions;
  flake.modules.homeManager.theme = themeOptions;
}
