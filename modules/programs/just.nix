{pkgs, ...}: {
  fireproof.home-manager.home.packages = [
    pkgs.unstable.just
  ];
}
