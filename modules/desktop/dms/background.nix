{inputs, ...}: {
  flake.modules.homeManager.dms-background = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (inputs.walldye.packages.${pkgs.stdenv.hostPlatform.system}.default) mkWallpaper;
    slugs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${inputs.walldye}/wallpapers"));
    # Real files, not a linkFarm: DMS saves resolved paths and browses their parent dir.
    background = pkgs.runCommand "desktop-background" {} "cp -rL ${wallpapers} $out";
    wallpapers = pkgs.linkFarm "walldye-wallpapers" (map (slug: {
        name = "${slug}.png";
        path = mkWallpaper {
          inherit slug;
          width = 3840;
          height = 2160;
        };
      })
      slugs);
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      # Stable path so a wallpaper picked in DMS survives rebuilds and GC; the default lives in dms/default.nix.
      xdg.dataFile.backgrounds.source = background;
    };
  };
}
