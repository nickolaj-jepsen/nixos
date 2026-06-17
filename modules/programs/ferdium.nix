# Aspect: gui-work
{
  flake.aspectTags.ferdium = ["gui-work"];
  flake.modules.homeManager.ferdium = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.unstable.ferdium
      ];
    };
  };
}
