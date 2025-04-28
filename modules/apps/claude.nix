{inputs, pkgs, ...}: {
  environment.systemPackages = [
    inputs.claude-desktop.packages.${pkgs.system}.claude-desktop-with-fhs
  ];
}