{
  pkgsUnstable,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = with pkgsUnstable; [
      opencode
      github-copilot-cli
    ];
  };
}
