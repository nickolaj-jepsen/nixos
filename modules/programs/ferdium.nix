# Aspect: gui-work
{
  flake.aspectTags.ferdium = ["gui-work"];
  flake.modules.homeManager.ferdium = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.work.enable) {
      home.packages = [
        pkgs.unstable.ferdium
      ];
    };
  };
}
