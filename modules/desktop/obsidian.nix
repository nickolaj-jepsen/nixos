{
  flake.modules.homeManager.obsidian = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.obsidian
      ];
    };
  };
}
