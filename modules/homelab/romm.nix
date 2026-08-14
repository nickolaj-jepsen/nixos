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
    # mergerfs only honours the caller's primary gid
    uid = config.users.users.media.uid;
    gid = config.users.groups.media.gid;
    envFile = config.age.secrets.romm-env.path;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      age.secrets.romm-env = {
        rekeyFile = ../../secrets/hosts/homelab/romm-env.age;
        owner = "postgres";
      };

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
        # peer auth would map the container's uid to media, not romm
        authentication = lib.mkBefore "local ${db} ${db} scram-sha-256";
      };

      # reapplies the password so a rotated secret takes effect
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
          # unix socket via DB_QUERY_JSON host=; DB_PORT still required (default 3306)
          DB_PORT = "5432";
          DB_QUERY_JSON = builtins.toJSON {host = "/run/postgresql";};

          OIDC_ENABLED = "true";
          OIDC_PROVIDER = "zitadel";
          # UI-only; /api/login + /api/token stay open on purpose (OIDC fallback)
          DISABLE_USERPASS_LOGIN = "true";
          OIDC_ALLOW_REGISTRATION = "false";
          OIDC_SERVER_APPLICATION_URL = "https://sso.${cfg.domain}";
          OIDC_REDIRECT_URI = "https://${domain}/api/oauth/openid";

          HASHEOUS_API_ENABLED = "true";
          PLAYMATCH_API_ENABLED = "true";
          HLTB_API_ENABLED = "true";
          LAUNCHBOX_API_ENABLED = "true";

          # scheduled, not inotify-based: mergerfs branch writes don't trigger it
          ENABLE_SCHEDULED_RESCAN = "true";
          ENABLE_SCHEDULED_CLEANUP_ORPHANED_RESOURCES = "true";
          ENABLE_SCHEDULED_RETROACHIEVEMENTS_PROGRESS_SYNC = "true";
          ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA = "true";

          WEB_SERVER_CONCURRENCY = "4";
        };
        environmentFiles = [envFile];
        volumes = [
          "${stateDir}/data:/romm"
          "${stateDir}/redis:/redis-data"
          "${library}:/romm/library"
          "/run/postgresql:/run/postgresql"
        ];
        ports = ["127.0.0.1:${toString port}:8080"];
        extraOptions = ["--user=${toString uid}:${toString gid}"];
      };

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
        # unlimited on purpose: RomM caps size via MAX_ASSET_UPLOAD_SIZE_BYTES
        extraConfig = ''
          client_max_body_size 0;
        '';
      };

      # only unrecoverable state: art rescans, DB is already in postgresqlBackup
      services.restic.backups.homelab.paths = [
        "${stateDir}/data/assets"
        "${stateDir}/data/config"
      ];
    };
  };
}
