# Aspect: google-chrome
{
  flake.aspectTags.google-chrome = ["google-chrome"];
  flake.modules.homeManager.google-chrome = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.google-chrome.enable) {
      programs.google-chrome = {
        enable = true;
        package = pkgs.unstable.google-chrome;
      };
    };
  };
}
