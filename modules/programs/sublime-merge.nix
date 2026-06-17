# Aspect: gui-dev
{
  flake.aspectTags.sublime-merge = ["gui-dev"];
  flake.modules.homeManager.sublime-merge = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.unstable.sublime-merge
      ];
    };
  };
}
