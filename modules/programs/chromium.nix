# Enabled when: desktop
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.chromium.enable) {
    fireproof.home-manager.programs.chromium = {
      enable = true;
      package = pkgsUnstable.chromium;
      extensions = [
        "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
        "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      ];
    };
  };
}
