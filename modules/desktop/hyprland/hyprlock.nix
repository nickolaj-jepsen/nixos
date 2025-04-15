{
  lib,
  config,
  inputs,
  pkgs,
  ...
}:
let 
   background = pkgs.stdenvNoCC.mkDerivation {
    pname = "desktop-background";
    version = "0.2";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./backgrounds/unknown.svg
      ];
    };

    nativeBuildInputs = [pkgs.inkscape];

    buildPhase = ''
      inkscape -w 3840 -h 2160 backgrounds/unknown.svg -o unknown.png
    '';

    installPhase = ''
      mkdir -p $out/share/backgrounds
      cp *.svg *.png $out/share/backgrounds
    '';
  };

  # Re-use the same color scheme as in the main Hyprland config
  color = {
    bg = "rgb(28, 27, 26)";
    ui = "rgb(52, 51, 49)";
    fg = "rgb(218, 216, 206)";
    transparent = "rgba(0, 0, 0, 0)";
  };
in {
  config = {
    fireproof.home-manager.programs.hyprlock = {
        enable = true;
        settings = {
          general = {
            disable_loading_bar = false;
            grace = 0;
            no_fade_in = false;
          };
          background = {
            monitor = "";
            color = color.bg;
            path = background + "/share/backgrounds/unknown.png";
          };
          input-field = {
            monitor = "";
            size = "250, 60";
            outline_thickness = 2;
            dots_size = 0.2;
            dots_spacing = 0.2;
            dots_center = true;
            outer_color = color.transparent;
            inner_color = color.ui;
            font_color = color.fg;
            fade_on_empty = false;
            font_family = "Hack Nerd Font";
            placeholder_text = "";
            hide_input = false;
            position = "0, -35";
            halign = "center";
            valign = "center";
            rounding = 8;
          };
          shape = [
            {
              monitor = "";
              color = color.ui;
              halign = "center";
              valign = "center";
              size = "150, 60";
              position = "0, 35";
              rounding = 8;
            }
          ];
          label = [
            {
              monitor = "";
              text = "cmd[update:1000] echo \"<span>$(date +\"%H:%M\")</span>\"";
              color = color.fg;
              font_size = 30;
              font_family = "Hack Nerd Font";
              position = "0, 35";
              halign = "center";
              valign = "center";
            }
          ];
      };
    };
  };
}