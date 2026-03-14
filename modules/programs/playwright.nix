# Enabled when: dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.playwright.enable {
    fireproof.home-manager.programs.fish.shellInit = ''
      set -xg PLAYWRIGHT_BROWSERS_PATH ${pkgs.unstable.playwright-driver.browsers}
      set -xg PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true
    '';
  };
}
