{lib, ...}: {
  options.fireproof.homelab = {
    enable = lib.mkEnableOption "Enable homelab services (arr, nginx, postgres, prometheus, etc.)";
  };

  imports = [
    ./arr.nix
    ./audiobookshelf.nix
    ./glance.nix
    ./home-assistant
    ./jellyfin.nix
    ./nextcloud.nix
    ./navidrome.nix
    ./nginx.nix
    ./plex.nix
    ./postgres.nix
    ./prometheus.nix
    ./qbittorrent.nix
    ./restic.nix
    ./security.nix
    ./sso
    ./vaultwarden.nix
  ];
}
