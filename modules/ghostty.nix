{
  pkgs,
  lib,
  ...
}: {
  service.terminal.default = lib.getExe pkgs.ghostty;
  environment.systemPackages = with pkgs; [
    ghostty
  ];
  user.home-manager = {
    programs.ghostty = {
      enable = true;
    };
  };
}
