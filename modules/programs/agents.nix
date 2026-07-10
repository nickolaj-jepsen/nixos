{
  flake.modules.homeManager.agents = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.github-copilot-cli
      ];
    };
  };
}
