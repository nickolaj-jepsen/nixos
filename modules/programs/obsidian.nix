# Aspect: desktop
{
  flake.aspectTags.obsidian = ["desktop"];

  flake.modules.homeManager.obsidian = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.packages = [
        pkgs.unstable.obsidian
      ];
    };
  };
}
