{
  flake.modules.homeManager.slack = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.slack
      ];
    };
  };
}
