{
  flake.modules.homeManager.chromium = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.chromium.enable && pkgs.stdenv.isLinux) {
      programs.chromium = {
        enable = true;
        package = pkgs.unstable.chromium;
        extensions = [
          "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
          "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
        ];
      };
    };
  };
}
