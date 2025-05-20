{
  pkgs,
  lib,
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
  pngs = [
    (background + "/share/backgrounds/unknown.png")
    (background + "/share/backgrounds/geometry.png")
  ];
in {
  fireproof.home-manager = {
    services.hyprpaper = {
      enable = true;
      settings = {
        preload = pngs;
        wallpaper = [",${builtins.head pngs}"];
      };
    };
  };
}
