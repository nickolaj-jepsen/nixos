{
  flake.modules.homeManager.slack = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      home.packages = [
        pkgs.unstable.slack
      ];
    };
  };
}
