# Aspect: dev
{
  flake.aspectTags.fnug = ["dev"];
  flake.modules.homeManager.fnug = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [pkgs.fnug];
    };
  };
}
