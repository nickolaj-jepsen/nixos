# RomM: ROM library manager, metadata scraper and in-browser player (EmulatorJS).
#
# Docker-only upstream, so it runs as an OCI container like grimmory/bm-cms; the
# image bundles its own Valkey (internal one starts only while REDIS_HOST is
# unset), so there is no second container.
#
# No oauth2-proxy gate: the download endpoints are consumed by ES-DE, Tinfoil and
# Playnite, none of which can do the OIDC browser flow the proxy demands.
{
  flake.modules.nixos.romm = {
    config,
    lib,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "romm.${cfg.domain}";
    # 8080 (RomM's default, still the container's port) is sabnzbd's on this host.
    port = 8085;
    library = "/mnt/data/roms";
    stateDir = "/var/lib/romm";
    db = "romm";
    # Runs as media: mergerfs honours only the caller's primary gid, so media must
    # be the primary group, not an extra one (same constraint as shelfmark.nix).
    uid = config.users.users.media.uid;
    gid = config.users.groups.media.gid;
    envFile = config.age.secrets.romm-env.path;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      # KEY=value, no shell/SQL metacharacters (the postgresql-setup hook below
      # sources it): DB_PASSWD, ROMM_AUTH_SECRET_KEY, OIDC_CLIENT_ID/SECRET, plus
      # any metadata-provider keys (IGDB, ScreenScraper, SteamGridDB,
      # RetroAchievements). owner=postgres lets that hook read it; root reads it
      # regardless.
      age.secrets.romm-env = {
        rekeyFile = ../../secrets/hosts/homelab/romm-env.age;
        owner = "postgres";
      };

      # The container depends on the daemon at boot; docker.nix defaults this off.
      virtualisation.docker.enableOnBoot = true;

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0750 ${toString uid} ${toString gid} -"
        "d ${stateDir}/data 0750 ${toString uid} ${toString gid} -"
        "d ${stateDir}/redis 0750 ${toString uid} ${toString gid} -"
        "d ${library} 0775 media media -"
      ];

      services.postgresql = fpLib.mkPostgresDB {
        name = db;
        login = true;
        # Peer auth would map the container's uid to media, not romm; mkBefore puts
        # this ahead of the default `local all all peer`.
        authentication = lib.mkBefore "local ${db} ${db} scram-sha-256";
      };

      # ensureUsers can't set a password; idempotent, so a rotated secret applies
      # on the next postgresql restart.
      systemd.services.postgresql-setup.postStart = lib.mkAfter ''
        set -a
        . ${envFile}
        set +a
        psql -tAc "ALTER ROLE ${db} WITH PASSWORD '$DB_PASSWD'"
      '';

      virtualisation.oci-containers.containers.romm = {
        image = "rommapp/romm:5.1.0";
        environment = {
          TZ = config.time.timeZone;
          ROMM_BASE_URL = "https://${domain}";
          ROMM_CORS_ALLOWED_ORIGINS = "https://${domain}";
          ROMM_SESSION_SECURE_COOKIE = "true";

          ROMM_DB_DRIVER = "postgresql";
          DB_NAME = db;
          DB_USER = db;
          # No socket option: RomM builds the URL from parts, and an unset DB_HOST
          # plus a libpq `host` query param is how SQLAlchemy expresses a unix
          # socket. DB_PORT defaults to 3306 (MariaDB's), so it must be set anyway.
          DB_PORT = "5432";
          DB_QUERY_JSON = builtins.toJSON {host = "/run/postgresql";};

          OIDC_ENABLED = "true";
          OIDC_PROVIDER = "zitadel";
          # UI-only: hides the login form but does NOT gate /api/login or
          # /api/token. The bootstrap admin stays reachable there on purpose, as
          # the way back in when OIDC breaks.
          DISABLE_USERPASS_LOGIN = "true";
          # Accounts are pre-created; an unknown Zitadel user gets a 403.
          OIDC_ALLOW_REGISTRATION = "false";
          OIDC_SERVER_APPLICATION_URL = "https://sso.${cfg.domain}";
          OIDC_REDIRECT_URI = "https://${domain}/api/oauth/openid";

          # Keyless providers; the keyed ones (IGDB, ScreenScraper, SteamGridDB,
          # RetroAchievements) come from the env file.
          HASHEOUS_API_ENABLED = "true";
          PLAYMATCH_API_ENABLED = "true";
          HLTB_API_ENABLED = "true";
          LAUNCHBOX_API_ENABLED = "true";

          # The RQ scheduler only starts if one of these is on. Preferred over
          # ENABLE_RESCAN_ON_FILESYSTEM_CHANGE: inotify on mergerfs misses writes
          # made straight to a branch rather than through /mnt/data.
          ENABLE_SCHEDULED_RESCAN = "true";
          ENABLE_SCHEDULED_CLEANUP_ORPHANED_RESOURCES = "true";
          ENABLE_SCHEDULED_RETROACHIEVEMENTS_PROGRESS_SYNC = "true";
          ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA = "true";

          # Upstream suggests 2×cores+1 (17 here), but this box also runs Plex,
          # Immich, Nextcloud and the arr stack.
          WEB_SERVER_CONCURRENCY = "4";
        };
        environmentFiles = [envFile];
        volumes = [
          "${stateDir}/data:/romm" # resources, assets (saves/states), config
          "${stateDir}/redis:/redis-data"
          "${library}:/romm/library"
          "/run/postgresql:/run/postgresql"
        ];
        ports = ["127.0.0.1:${toString port}:8080"];
        # Upstream supports a non-root uid: it only drops nginx to its own `romm`
        # user when EUID is 0.
        extraOptions = ["--user=${toString uid}:${toString gid}"];
      };

      # postgresql.target (not .service) also pulls in postgresql-setup, which sets
      # the role password. The container exits if its startup migration fails.
      systemd.services.docker-romm = {
        after = ["postgresql.target"];
        requires = ["postgresql.target"];
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = "15s";
        };
      };

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true;
        # Multi-GB ROM uploads; RomM limits them via MAX_ASSET_UPLOAD_SIZE_BYTES.
        extraConfig = ''
          client_max_body_size 0;
        '';
      };

      # The only unrecoverable state: resources/ is scraped art a rescan
      # re-downloads, and the database is already in the postgresqlBackup dump.
      services.restic.backups.homelab.paths = [
        "${stateDir}/data/assets"
        "${stateDir}/data/config"
      ];
    };
  };
}
