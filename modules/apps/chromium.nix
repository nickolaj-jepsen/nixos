{pkgsUnstable, ...}: {
  fireproof.home-manager.programs.chromium = {
    enable = true;
    package = pkgsUnstable.chromium;
    extensions = [
      "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
    ];
  };
}
