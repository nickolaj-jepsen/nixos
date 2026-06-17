{
  flake.aspectTags.agents = ["dev"];
  flake.modules.homeManager.agents = {
    pkgs,
    lib,
    config,
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
