{pkgs, ...}: {
  fireproof.home-manager.programs.fish.shellInit = ''
    set -xg PLAYWRIGHT_BROWSERS_PATH ${pkgs.playwright-driver.browsers}
    set -xg PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true
  '';
}