{
  flake.aspectTags.chromium = ["chromium"];
  flake.modules.homeManager.chromium = {
    pkgs,
    ...
  }: {
    config = {
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
