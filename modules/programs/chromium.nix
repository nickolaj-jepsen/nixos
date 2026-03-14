# Enabled when: desktop
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.fireproof.desktop.chromium.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.fireproof.desktop.enable;
    description = "Enable Chromium";
  };

  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.chromium.enable) {
    fireproof.home-manager.programs.chromium = {
      enable = true;
      package = pkgs.unstable.chromium;
      extensions = [
        "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
        "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      ];
    };
  };
}
