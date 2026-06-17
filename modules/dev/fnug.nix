{
  flake.modules.homeManager.fnug = {pkgs, ...}: {
    config = {
      home.packages = [pkgs.fnug];
    };
  };
}
