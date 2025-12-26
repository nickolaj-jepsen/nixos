# Enabled when: desktop & dev
{
  config,
  lib,
  pkgsUnstable,
  ...
}: let
  pycharmPkg = pkgsUnstable.jetbrains.pycharm.override {
    # -Dide.browser.jcef.enabled causes crashes on wayland
    vmopts = ''
      -Dide.browser.jcef.enabled=false
      -Dawt.toolkit.name=WLToolkit
      -Xmx8G
    '';
  };
  # pycharmWithPlugins = pkgsUnstable.jetbrains.plugins.addPlugins pycharmPkg [
  #   "github-copilot"
  # ];
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    environment.systemPackages = [
      pycharmPkg
    ];
  };
}
