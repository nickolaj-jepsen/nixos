{
  pkgs,
  lib,
  ...
}: let
  background = pkgs.stdenvNoCC.mkDerivation {
    pname = "desktop-background";
    version = "0.1";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./background.svg
      ];
    };

    nativeBuildInputs = [pkgs.inkscape];

    buildPhase = ''
      inkscape -w 3840 -h 2160 background.svg -o background.png
    '';

    installPhase = ''
      mkdir -p $out/share/backgrounds
      cp *.svg *.png $out/share/backgrounds
    '';
  };
  png = background + "/share/backgrounds/background.png";
in {
  fireproof.home-manager = {
    services.hyprpaper = {
      enable = true;
      settings = {
        preload = [png];
        wallpaper = [",${png}"];
      };
    };
  };
}
