{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.unstable.just
  ];
}
