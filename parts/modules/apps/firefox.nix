{pkgs, ...}: {
  programs.firefox.enable = true;
  defaults.browser = pkgs.firefox;
}
