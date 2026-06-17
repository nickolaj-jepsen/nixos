# Aspect: gui-dev
{
  flake.aspectTags.sublime-merge = ["gui-dev"];
  flake.modules.homeManager.sublime-merge = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      home.packages = [
        pkgs.unstable.sublime-merge
      ];
    };
  };
}
