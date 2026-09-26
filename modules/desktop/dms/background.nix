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
        printf '%s\0' *.svg | xargs -0 -P "$NIX_BUILD_CORES" -I{} \
          sh -c 'inkscape -w 3840 -h 2160 "$1" -o "''${1%.svg}.png"' _ {}
      '';

      installPhase = ''
        mkdir -p $out/share/backgrounds
        cp *.png $out/share/backgrounds
      '';
    };
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      # Stable path so a wallpaper picked in DMS survives rebuilds and GC; the default lives in dms/default.nix.
      xdg.dataFile.backgrounds.source = "${background}/share/backgrounds";
    };
  };
}
