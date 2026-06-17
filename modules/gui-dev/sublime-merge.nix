{
  flake.modules.homeManager.sublime-merge = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.sublime-merge
      ];
    };
  };
}
