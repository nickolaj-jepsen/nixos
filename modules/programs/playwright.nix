# Enabled when: dev
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    fireproof.home-manager.programs.fish.shellInit = ''
      set -xg PLAYWRIGHT_BROWSERS_PATH ${pkgsUnstable.playwright-driver.browsers}
      set -xg PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true
    '';
  };
}
