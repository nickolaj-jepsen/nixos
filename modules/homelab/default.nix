{lib, ...}: {
  options.fireproof.homelab = {
    enable = lib.mkEnableOption "Enable homelab services (arr, nginx, postgres, prometheus, etc.)";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "nickolaj.com";
      description = "Root domain used for homelab service hostnames.";
    };
    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "nickolaj@fireproof.website";
      description = "Contact email registered with the ACME provider.";
    };
  };

  imports = [
    ./arr.nix
    ./attic.nix
    ./audiobookshelf.nix
    ./glance
    ./home-assistant
    ./immich.nix
    ./jellyfin.nix
    ./monitoring
    ./nextcloud.nix
    ./navidrome.nix
    ./nginx.nix
    ./plex.nix
    ./postgres.nix
    ./qbittorrent.nix
    ./restic.nix
    ./security.nix
    ./sso
    ./vaultwarden.nix
  ];
}
