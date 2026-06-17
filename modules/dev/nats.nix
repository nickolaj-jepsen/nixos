{
  flake.modules.homeManager.nats = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.unstable.natscli
      ];
    };
  };
}
