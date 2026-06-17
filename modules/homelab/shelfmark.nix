{
  flake.aspectTags.shelfmark = ["shelfmark"];
  flake.modules.nixos.shelfmark = {
    config,
    lib,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "shelfmark.${cfg.domain}";
    port = 8084;
    library = "/mnt/data/books";
  in {
    config = lib.mkIf cfg.enable {
      services.restic.backups.homelab.paths = [config.services.shelfmark.environment.CONFIG_DIR];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true; # live download-queue status updates
      };

      # Acquisition tool, same class as the *arr stack — gate it behind SSO rather
      # than relying on Shelfmark's own auth (which is unset until configured in-app).
      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["arr"];

      services.shelfmark = {
        enable = true;
        environment = {
          FLASK_HOST = "127.0.0.1"; # only nginx reaches it
          FLASK_PORT = port;
          INGEST_DIR = library; # land downloads in the library Kavita/Audiobookshelf scan
        };
      };

      # /mnt/data is a mergerfs FUSE mount, which only honours the caller's *primary*
      # gid — supplementary groups don't grant access. So, like every other media
      # service here (arr, audiobookshelf), run as media:media rather than under the
      # upstream unit's DynamicUser. ReadWritePaths re-opens the library through
      # ProtectSystem=strict; UMask 0022 keeps downloads world-readable so Kavita and
      # Audiobookshelf can read them.
      systemd.services.shelfmark.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "media";
        Group = "media";
        ReadWritePaths = [library];
        PrivateUsers = lib.mkForce false;
        UMask = lib.mkForce "0022";
      };
    };
  };
}
