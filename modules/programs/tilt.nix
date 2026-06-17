# Aspect: dev
{
  flake.aspectTags.tilt = ["dev"];
  flake.modules.homeManager.tilt = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.unstable.tilt
      ];
    };
  };
}
