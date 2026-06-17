{
  flake.aspectTags.zellij = ["base"];
  flake.modules.homeManager.zellij = {pkgs, ...}: {
    config = {
      programs.zellij = {
        enable = true;
        package = pkgs.unstable.zellij;
      };
    };
  };
}
