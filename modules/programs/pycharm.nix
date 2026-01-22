# Enabled when: desktop & dev
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.intellij.enable) (let
    pycharmPkg = pkgsUnstable.jetbrains.pycharm.override {
      # -Dide.browser.jcef.enabled causes crashes on wayland
      vmopts = ''
        -Dide.browser.jcef.enabled=false
        -Dawt.toolkit.name=WLToolkit
        -Xmx8G
      '';
    };
  in {
    environment.systemPackages = [
      pycharmPkg
    ];
  });
}
