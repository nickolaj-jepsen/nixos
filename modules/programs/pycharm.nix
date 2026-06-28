# PyCharm Professional. On darwin a Homebrew cask; the nixpkgs build (Wayland-tuned
# vmopts below) is Linux-only.
{
  flake.modules.darwin.pycharm = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.intellij.enable) {
      homebrew.casks = ["pycharm"];
    };
  };

  flake.modules.homeManager.pycharm = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.intellij.enable && pkgs.stdenv.isLinux) (let
      pycharmPkg = pkgs.unstable.jetbrains.pycharm.override {
        # -Dide.browser.jcef.enabled causes crashes on wayland
        vmopts = ''
          -Dide.browser.jcef.enabled=false
          -Dawt.toolkit.name=WLToolkit
          -Xmx8G
        '';
      };
    in {
      home.packages = [
        pycharmPkg
      ];
    });
  };
}
