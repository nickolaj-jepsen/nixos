{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.fuzzel
  ];
}
