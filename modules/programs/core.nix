{pkgs, ...}: {
  config = {
    environment.enableAllTerminfo = true;

    # Fundamental system utilities that should stay system-level
    environment.systemPackages = with pkgs; [
      file
      findutils
      which
      gnugrep
      gawk
      gnused
      lshw
    ];

    fireproof.home-manager = {
      programs = {
        fzf.enable = true;
        tmux.enable = true;
        ripgrep.enable = true;
        jq.enable = true;
        htop.enable = true;
        man.enable = true;
      };

      home.packages = with pkgs; [
        man-pages
        man-pages-posix
        curl
        wget
        whois
        rsync
        tree
        zip
        unzip
        gzip
        xz
      ];
    };
  };
}
