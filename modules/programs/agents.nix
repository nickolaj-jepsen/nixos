{
  pkgs,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    fireproof.home-manager.home.packages = with pkgs.unstable; [
      github-copilot-cli
      opencode
      beads
    ];
  };
}
