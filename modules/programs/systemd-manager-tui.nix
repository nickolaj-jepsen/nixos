{pkgsUnstable, ...}: {
  environment.systemPackages = [
    pkgsUnstable.systemd-manager-tui
  ];
}
