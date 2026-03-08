{
  pkgs,
  pkgsUnstable,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages =
      (with pkgs; [
        github-copilot-cli
      ])
      ++ (with pkgsUnstable; [
        opencode
        beads
      ]);
  };
}
