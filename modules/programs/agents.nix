{
  pkgs,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    fireproof.home-manager.home.packages =
      (with pkgs; [
        github-copilot-cli
      ])
      ++ (with pkgs.unstable; [
        opencode
        beads
      ]);
  };
}
