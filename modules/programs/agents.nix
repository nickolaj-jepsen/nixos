{
  pkgs,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages =
      (with pkgs; [
        github-copilot-cli
      ])
      ++ (with pkgs.unstable; [
        opencode
        beads
      ]);
  };
}
