{
  pkgs,
  config,
  lib,
  ...
}: {
  defaults.terminal = lib.getExe pkgs.ghostty;
  environment.systemPackages = with pkgs; [
    ghostty
  ];
  user.home-manager = {
    programs.ghostty = {
      enable = true;
      enableFishIntegration = config.programs.fish.enable;
    };
  };
}
