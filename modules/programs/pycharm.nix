{
  flake.aspectTags.pycharm = ["intellij"];
  # Aspect: intellij
  flake.modules.homeManager.pycharm = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.intellij.enable) (let
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
