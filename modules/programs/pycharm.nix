{
  flake.aspectTags.pycharm = ["intellij"];
  # Aspect: intellij
  flake.modules.homeManager.pycharm = {
    pkgs,
    ...
  }: {
    config = let
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
    };
  };
}
