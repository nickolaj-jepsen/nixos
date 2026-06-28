{
  flake.modules.homeManager.dms-background = {
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
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      # hyprpaper: DMS can't set wallpapers yet
      services.hyprpaper = {
        enable = true;
        settings = {
          splash = false;
          preload = pngs;
          wallpaper = [
            {
              monitor = "*";
              path = builtins.head pngs;
            }
          ];
        };
      };

      programs.dank-material-shell.settings = {
        # disable DMS wallpaper mgmt to avoid conflicting with hyprpaper
        screenPreferences.wallpaper = [];
      };

      programs.dank-material-shell.session = {
        wallpaperPath = unknownPng;
      };
    };
  };
}
