{
  flake.modules.homeManager.emdash = {pkgs, ...}: {
    config = {
      home.packages = [pkgs.emdash];
    };
  };
}
