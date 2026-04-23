{pkgs, ...}: {
  fireproof.home-manager = {
    programs.zellij = {
      enable = true;
      package = pkgs.unstable.zellij;
    };
  };
}
