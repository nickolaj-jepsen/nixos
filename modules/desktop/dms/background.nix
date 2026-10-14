{inputs, ...}: {
  flake.modules.homeManager.dms-background = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (inputs.walldye.packages.${pkgs.stdenv.hostPlatform.system}.default) mkWallpaper;
    slugs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${inputs.walldye}/wallpapers"));
    mkBackgrounds = width: height:
      pkgs.linkFarm "walldye-${toString width}x${toString height}" (map (slug: {
          name = "${slug}.png";
          path = mkWallpaper {inherit slug width height;};
        })
        slugs);
    backgrounds = {
      backgrounds = mkBackgrounds 3840 2160;
      # walldye lays each design out for the aspect, so rotated monitors get a real portrait composition.
      backgrounds-portrait = mkBackgrounds 2160 3840;
    };
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      # Copied, not linked: DMS saves the resolved path of a picked wallpaper, which must survive rebuilds and GC.
      # The defaults live in dms/default.nix.
      home.activation.dmsBackgrounds = lib.hm.dag.entryAfter ["linkGeneration"] (lib.concatStrings (lib.mapAttrsToList (dir: src: ''
          run ${lib.getExe pkgs.rsync} -rLt --delete --chmod=u+w ${src}/ ${config.xdg.dataHome}/${dir}/
        '')
        backgrounds));
    };
  };
}
