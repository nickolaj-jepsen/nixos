{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.nodejs
  ];
}
