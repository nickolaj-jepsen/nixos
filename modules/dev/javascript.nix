{
  flake.modules.homeManager.javascript = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.nodejs
        pkgs.unstable.pnpm
        pkgs.turbo-unwrapped
      ];
    };
  };
}
