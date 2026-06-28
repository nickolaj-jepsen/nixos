{
  flake.modules.homeManager.bambu-studio = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.bambu-studio.enable && pkgs.stdenv.isLinux) {
      home.packages = [
        pkgs.bambu-studio
      ];
    };
  };
}
