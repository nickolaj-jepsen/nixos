# Enabled when: desktop + opt-in
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.fireproof.desktop.google-chrome.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable Google Chrome";
  };

  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.google-chrome.enable) {
    fireproof.home-manager.programs.google-chrome = {
      enable = true;
      package = pkgs.unstable.google-chrome;
    };
  };
}
