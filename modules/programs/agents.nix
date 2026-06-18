{
  flake.modules.homeManager.agents = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = with pkgs.unstable; [
        github-copilot-cli
        opencode
        beads
      ];
    };
  };
}
