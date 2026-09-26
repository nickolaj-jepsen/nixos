{
  flake.modules.homeManager.dms-background = {
    config,
    lib,
    pkgs,
    ...
  }: let
    background = pkgs.stdenvNoCC.mkDerivation {
      pname = "desktop-background";
      version = "0.3";

      src = lib.fileset.toSource {
        root = ./backgrounds;
        fileset = lib.fileset.fileFilter (file: file.hasExt "svg") ./backgrounds;
      };

      nativeBuildInputs = [pkgs.inkscape];

      buildPhase = ''
        for svg in *.svg; do
          inkscape -w 3840 -h 2160 "$svg" -o "''${svg%.svg}.png"
        done
      '';

      installPhase = ''
        mkdir -p $out/share/backgrounds
        cp *.svg *.png $out/share/backgrounds
      '';
    };
    activeWallpaper = background + "/share/backgrounds/unknown.png";
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      # hyprpaper: DMS can't set wallpapers yet
      services.hyprpaper = {
        enable = true;
        settings = {
          splash = false;
          # Preload only the active one; each decoded 4K PNG costs ~33 MB.
          preload = [activeWallpaper];
          wallpaper = [
            {
              monitor = "*";
              path = activeWallpaper;
            }
          ];
        };
      };

      programs.dank-material-shell.settings = {
        # disable DMS wallpaper mgmt to avoid conflicting with hyprpaper
        screenPreferences.wallpaper = [];
      };

      programs.dank-material-shell.session = {
        wallpaperPath = activeWallpaper;
      };
    };
  };
}
