{
  config,
  lib,
  pkgs,
  ...
}: let
  background = pkgs.stdenvNoCC.mkDerivation {
    pname = "desktop-background";
    version = "0.2";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./backgrounds/geometry.svg
        ./backgrounds/unknown.svg
      ];
    };

    nativeBuildInputs = [pkgs.inkscape];

    buildPhase = ''
      inkscape -w 3840 -h 2160 backgrounds/geometry.svg -o geometry.png
      inkscape -w 3840 -h 2160 backgrounds/unknown.svg -o unknown.png
    '';

    installPhase = ''
      mkdir -p $out/share/backgrounds
      cp *.svg *.png $out/share/backgrounds
    '';
  };
  unknownPng = background + "/share/backgrounds/unknown.png";
  geometryPng = background + "/share/backgrounds/geometry.png";
  pngs = [
    unknownPng
    geometryPng
  ];
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      # Use hyprpaper as we can't currently set wallpapers through DMS
      services.hyprpaper = {
        enable = true;
        settings = {
          preload = pngs;
          wallpaper = [",${builtins.head pngs}"];
        };
      };

      programs.dank-material-shell.default.settings = {
        # Disables wallpaper management in DMS to avoid conflicts with Hyprpaper
        screenPreferences.wallpaper = [];
      };

      programs.dank-material-shell.default.session = {
        # Attempt to set a default wallpaper on first run
        wallpaperPath = unknownPng;
      };
    };
  };
}
