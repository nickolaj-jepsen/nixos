{
  flake.modules.homeManager.zellij = {pkgs, ...}: {
    programs.zellij = {
      enable = true;
      package = pkgs.unstable.zellij;
    };
  };
}
