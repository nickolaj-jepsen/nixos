{
  flake.modules.homeManager.tilt = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.tilt
      ];
    };
  };
}
