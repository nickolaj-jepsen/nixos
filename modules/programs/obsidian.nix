# Aspect: desktop
{
  flake.aspectTags.obsidian = ["desktop"];

  flake.modules.homeManager.obsidian = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.unstable.obsidian
      ];
    };
  };
}
