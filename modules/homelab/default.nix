{lib, ...}: {
  options.fireproof.homelab = {
    enable = lib.mkEnableOption "Enable homelab services (arr, nginx, postgres, prometheus, etc.)";
  };

  imports = [
    ./arr.nix
    ./audiobookshelf.nix
    ./glance.nix
    ./home-assistant.nix
    ./jellyfin.nix
    ./nextcloud.nix
    ./nginx.nix
    ./plex.nix
    ./postgres.nix
    ./prometheus.nix
    ./restic.nix
    ./sso.nix
    ./vaultwarden.nix
  ];
}
