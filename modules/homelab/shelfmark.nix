{
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
    config = lib.mkIf config.fireproof.homelab.enable {
      services.restic.backups.homelab.paths = [config.services.shelfmark.environment.CONFIG_DIR];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true;
      };

      # Gate behind SSO: Shelfmark's own auth is unset until configured in-app.
      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["arr"];

      services.shelfmark = {
        enable = true;
        environment = {
          FLASK_HOST = "127.0.0.1";
          FLASK_PORT = port;
          INGEST_DIR = library;
        };
      };

      # mergerfs FUSE honours only the caller's primary gid, so run as media:media (not DynamicUser); UMask 0022 keeps downloads world-readable for Kavita/Audiobookshelf.
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
