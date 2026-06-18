{
  flake.modules.homeManager.just = {pkgs, ...}: {
    home.packages = [
      pkgs.unstable.just
    ];
  };
}
