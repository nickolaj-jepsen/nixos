{
  flake.aspectTags.slack = ["gui-work"];
  # Aspect: gui-work
  flake.modules.homeManager.slack = {
    pkgs,
    ...
  }: {
    config = {
      home.packages = [
        pkgs.unstable.slack
      ];
    };
  };
}
