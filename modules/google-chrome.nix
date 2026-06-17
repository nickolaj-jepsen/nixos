{
  flake.modules.homeManager.google-chrome = {pkgs, ...}: {
    config = {
      programs.google-chrome = {
        enable = true;
        package = pkgs.unstable.google-chrome;
      };
    };
  };
}
