{
  flake.modules.homeManager.agents = {pkgs, ...}: {
    config = {
      home.packages = with pkgs.unstable; [
        github-copilot-cli
        opencode
        beads
      ];
    };
  };
}
