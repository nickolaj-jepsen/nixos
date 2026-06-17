{
  flake.modules.homeManager.clipboard = {pkgs, ...}: {
    config = {
      home.packages = [pkgs.wl-clipboard];
    };
  };
}
