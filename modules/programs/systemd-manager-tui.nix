{pkgs, ...}: {
  fireproof.home-manager.home.packages = [
    pkgs.unstable.systemd-manager-tui
  ];
}
