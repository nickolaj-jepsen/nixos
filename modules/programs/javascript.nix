# Enabled when: dev
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = [
      pkgs.nodejs
      pkgs.unstable.pnpm
      pkgs.turbo-unwrapped
    ];
  };
}
