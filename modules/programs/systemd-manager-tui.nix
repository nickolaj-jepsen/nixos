{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.unstable.systemd-manager-tui
  ];
}
