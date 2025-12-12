{lib, ...}: {
  options.fireproof.homelab = {
    enable = lib.mkEnableOption "Enable homelab services (arr, nginx, postgres, prometheus, etc.)";
  };

  imports = [
    ./arr.nix
    ./flame.nix
    ./home-assistant.nix
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
