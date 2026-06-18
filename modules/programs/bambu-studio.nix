{
  flake.modules.homeManager.bambu-studio = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.bambu-studio.enable) {
      home.packages = [
        pkgs.bambu-studio
      ];
    };
  };
}
