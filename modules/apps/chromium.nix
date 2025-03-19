{pkgsUnstable, ...}: {
  fireproof.home-manager.programs.chromium = {
    enable = true;
    package = pkgsUnstable.ungoogled-chromium;
    extensions = [
      "cjpalhdlnbpafiamejdnhcphjbkeiagm" # uBlock Origin
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
    ];
  };
}
