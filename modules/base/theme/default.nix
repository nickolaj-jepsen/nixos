# Flexoki-inspired (https://stephango.com/flexoki); emitted to every class so HM can read colors without an osConfig bridge.
{inputs, ...}: let
  themeOptions = {
    config,
    options,
    lib,
    pkgs,
    ...
  }: let
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

    # Fixed brand identity, deliberately not derived from the palette above.
    options.fireproof.theme.brand.flame = {
      outer = mkColorOption "F46200" "Logo flame outer layer; also the \"fire\" in the wordmark";
      mid = mkColorOption "FF8000" "Logo flame middle layer";
      core = mkColorOption "FFD500" "Logo flame core";
    };

    options.fireproof.theme.designSystem = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ./_design-system.nix {
        inherit lib pkgs;
        theme = {inherit (config.fireproof.theme) colors brand font;};
        descriptions = lib.mapAttrs (_: opt: opt.description) options.fireproof.theme.colors;
      };
      defaultText = lib.literalMD "built from the other `fireproof.theme` options";
      description = "Design-system bundle: `tokens.css`, `tokens.json`, `logo/*.svg`, `fonts/` and a specimen `index.html`";
    };

    options.fireproof.theme.font = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.nerd-fonts.hack;
        defaultText = lib.literalExpression "pkgs.nerd-fonts.hack";
        description = "Font package providing `family` and `monoFamily`";
      };
      family = lib.mkOption {
        type = lib.types.str;
        default = "Hack Nerd Font";
        description = "Font family for terminals and editors";
      };
      monoFamily = lib.mkOption {
        type = lib.types.str;
        default = "Hack Nerd Font Mono";
        description = "Strictly monospaced variant of `family`, for UIs that need fixed-width glyphs";
      };
      sans = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.nunito-sans;
          defaultText = lib.literalExpression "pkgs.nunito-sans";
          description = "Font package providing `sans.family`";
        };
        family = lib.mkOption {
          type = lib.types.str;
          default = "Nunito Sans";
          description = "Proportional font family for UI text";
        };
      };
    };
  };
in {
  flake.modules.nixos.theme = themeOptions;
  flake.modules.homeManager.theme = themeOptions;
  # Emitted to darwin too so shared cards' theme options type-check there.
  flake.modules.darwin.theme = themeOptions;

  # Taken from a host so it reflects the theme actually in effect; Linux-only, like that host.
  perSystem = {
    lib,
    system,
    ...
  }: {
    packages = let
      inherit (inputs.self.nixosConfigurations) desktop;
    in
      lib.optionalAttrs (system == desktop.pkgs.stdenv.hostPlatform.system) {
        design-system = desktop.config.fireproof.theme.designSystem;
      };
  };
}
