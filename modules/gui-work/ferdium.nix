{
  flake.modules.homeManager.ferdium = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.ferdium
      ];
    };
  };
}
