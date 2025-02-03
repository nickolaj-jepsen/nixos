{pkgs, ...}: {
  config = {
    environment.systemPackages = with pkgs; [
      curl
      wget
      file
      git
      htop
      jq
      ripgrep
      tmux
      whois
      man-pages
      man-pages-posix
    ];
  };
}
