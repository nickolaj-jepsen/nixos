{pkgs, ...}: {
  config = {
    environment.systemPackages = with pkgs; [
      # Man pages
      man-pages
      man-pages-posix

      # Networking
      curl
      wget
      whois
      rsync

      # Shell
      tmux
      fzf

      # Files
      file
      findutils
      which
      tree

      # Text processing
      ripgrep
      jq
      gnugrep
      gawk
      gnused

      # Monitoring
      htop
      btop
      lshw

      # Archive
      zip
      unzip
      gzip
      xz

      # Nix
      nurl
    ];
  };
}
