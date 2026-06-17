# Aspect: google-chrome
{
  flake.aspectTags.google-chrome = ["google-chrome"];
  flake.modules.homeManager.google-chrome = {
    pkgs,
    ...
  }: {
    config = {
      programs.google-chrome = {
        enable = true;
        package = pkgs.unstable.google-chrome;
      };
    };
  };
}
