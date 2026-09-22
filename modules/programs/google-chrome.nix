# Google Chrome on darwin: a Homebrew cask, the Mac browser-extra (chromium is
# Linux-only here).
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
}
