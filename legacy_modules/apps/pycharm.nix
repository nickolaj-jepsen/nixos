{pkgsUnstable, ...}: let
  pycharmPkg = pkgsUnstable.jetbrains.pycharm-professional.override {
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
  environment.systemPackages = [
    pycharmPkg
  ];
}
