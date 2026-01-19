{
  inputs,
  pkgs,
  lib,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = with inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}; [
      # opencode
      # desktop
    ];
  };
}
