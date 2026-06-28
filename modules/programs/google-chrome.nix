# Google Chrome. On darwin a Homebrew cask (the Mac browser-extra, since chromium
# is Linux-only here); on Linux an opt-in nixpkgs build via desktop.google-chrome.enable.
{
  flake.modules.darwin.google-chrome = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["google-chrome"];
    };
  };

  flake.modules.homeManager.google-chrome = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.google-chrome.enable && pkgs.stdenv.isLinux) {
      programs.google-chrome = {
        enable = true;
        package = pkgs.unstable.google-chrome;
      };
    };
  };
}
