# Grimmory (maintained community fork of BookLore): EPUB/PDF library with a web
# reader, OPDS, and a native KOReader kosync endpoint for two-way read-progress
# sync — the gap that made Kavita unsuitable. Replaces kavita.nix once migrated.
#
# Docker-only upstream (Spring Boot), so the app runs as an OCI container (the
# homelab's first; docker backend is set fleet-wide in programs/docker.nix). It only
# speaks MySQL/MariaDB, so it uses the shared native MariaDB engine
# (modules/homelab/mariadb.nix) — declaring its database and a TCP password user
# here, and reaching host MariaDB over the docker bridge gateway.
#
# The shared /mnt/data/books library is mounted read-only with DISK_TYPE=NETWORK so
# Grimmory only indexes it — it never rewrites files and so can't fight Shelfmark,
# Audiobookshelf or Kavita over the same tree (read-only also means a world-readable
# mount is enough, no uid juggling). Shelfmark already drops downloads into that
# path, so the "Shelfmark integration" is just the shared library.
{
  flake.modules.nixos.grimmory = {
    config,
    lib,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "grimmory.${cfg.domain}";
    port = 6060;
    library = "/mnt/data/books";
    stateDir = "/var/lib/grimmory";
    db = "grimmory";
    # Dedicated, pinned id for the container process; only owns stateDir. /books is
    # read-only + world-readable, so this id needs no membership in the media group.
    uid = 2000;
    gid = 2000;
    envFile = config.age.secrets.grimmory-env.path;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      # Single secret line: DATABASE_PASSWORD=<alphanumeric> — read by the container
      # (docker --env-file) and sourced by the MariaDB hook below, so keep it free of
      # shell/SQL metacharacters. owner=mysql lets that hook read it; root (dockerd)
      # reads it regardless.
      age.secrets.grimmory-env = {
        rekeyFile = ../../secrets/hosts/homelab/grimmory-env.age;
        owner = "mysql";
      };

      # The container depends on the daemon at boot; docker.nix defaults this off.
      virtualisation.docker.enableOnBoot = true;

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0750 ${toString uid} ${toString gid} -"
        "d ${stateDir}/data 0750 ${toString uid} ${toString gid} -"
      ];

      # Declare our database + backup against the shared MariaDB engine (mariadb.nix).
      services.mysql.ensureDatabases = [db];
      services.mysqlBackup.databases = [db];

      # ensureUsers only does socket auth; the container logs in over TCP with a
      # password, so provision the user here. Idempotent and re-applied each start, so
      # rotating the secret just takes effect on the next restart.
      systemd.services.mysql.postStart = lib.mkAfter ''
        set -a
        . ${envFile}
        set +a
        ${config.services.mysql.package}/bin/mysql -N -e \
          "CREATE USER IF NOT EXISTS '${db}'@'%' IDENTIFIED BY '$DATABASE_PASSWORD';
           ALTER USER '${db}'@'%' IDENTIFIED BY '$DATABASE_PASSWORD';
           GRANT ALL PRIVILEGES ON ${db}.* TO '${db}'@'%';"
      '';

      virtualisation.oci-containers.containers.grimmory = {
        image = "grimmory/grimmory:v3.2.2";
        environment = {
          USER_ID = toString uid;
          GROUP_ID = toString gid;
          TZ = config.time.timeZone;
          DATABASE_URL = "jdbc:mariadb://host.docker.internal:3306/${db}";
          DATABASE_USERNAME = db;
          # Treat the shared library as read-only: index metadata into the DB,
          # never touch the files (keeps KOReader content hashes stable).
          DISK_TYPE = "NETWORK";
          SWAGGER_ENABLED = "false";
        };
        environmentFiles = [envFile]; # DATABASE_PASSWORD
        volumes = [
          "${stateDir}/data:/app/data"
          "${library}:/books:ro"
        ];
        ports = ["127.0.0.1:${toString port}:${toString port}"];
        # Resolve the host (running MariaDB) from inside the default bridge.
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
      };

      systemd.services.docker-grimmory = {
        after = ["mysql.service"];
        requires = ["mysql.service"];
        # Spring Boot can outrace a cold MariaDB; let systemd retry instead.
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = "15s";
        };
      };

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true;
      };
      # NB: no oauth2-proxy gate — KOReader's OPDS + kosync auth can't do the OIDC
      # browser flow, so the vhost relies on Grimmory's own per-user credentials.

      services.restic.backups.homelab.paths = ["${stateDir}/data"];
    };
  };
}
