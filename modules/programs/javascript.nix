# Enabled when: dev
{
  config,
  lib,
  pkgs,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = [
      pkgs.nodejs
      pkgsUnstable.pnpm
      pkgs.turbo-unwrapped
    ];
  };
}
