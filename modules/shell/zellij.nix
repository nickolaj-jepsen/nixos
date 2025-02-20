{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    zellij
  ];

  fireproof.home-manager = {
    programs.zellij = {
      enable = true;
    };
  };
}
