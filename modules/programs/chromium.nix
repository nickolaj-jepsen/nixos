# Enabled when: desktop
{
  config,
  lib,
  pkgs,
  ...
}: {
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
