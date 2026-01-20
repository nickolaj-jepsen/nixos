{
  pkgs,
  lib,
  ...
}: let
  makeScript = {
    path,
    name ? lib.removeSuffix ".bash" (builtins.baseNameOf path),
    runtimeInputs ? [],
  }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = builtins.readFile path;
    };
in {
  environment.systemPackages = [
    (makeScript {
      path = ./reboot-windows.bash;
      runtimeInputs = with pkgs; [
        jq
        systemd # for bootctl and systemctl
      ];
    })
  ];
}
