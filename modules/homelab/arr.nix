{fpLib, ...}: {
  flake.modules.nixos.arr = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.fireproof) username;
    cfg = config.fireproof.homelab;
    user = "media";
    group = "media";

    # Live WAL-mode DBs that restic must not copy; arr-db-dump snapshots them instead.
    dumpDir = "/var/backup/arr";
    mediaDb = path: {
      inherit path;
      resticPath = path;
      runAs = ["User=${user}"];
    };
    dbs = {
      radarr = mediaDb "${config.services.radarr.dataDir}/radarr.db";
      sonarr = mediaDb "${config.services.sonarr.dataDir}/sonarr.db";
      lidarr = mediaDb "${config.services.lidarr.dataDir}/lidarr.db";
      bazarr = mediaDb "${config.services.bazarr.dataDir}/db/bazarr.db";
      sabnzbd = mediaDb "/var/lib/sabnzbd/admin/history1.db";
      prowlarr = {
        path = "${config.services.prowlarr.dataDir}/prowlarr.db";
        resticPath = "/var/lib/private/prowlarr/prowlarr.db";
        # DynamicUser: /var/lib/private is root-only, so reach the DB through a StateDirectory mount (reuses the dir owner's uid).
        runAs = ["DynamicUser=yes" "User=prowlarr" "StateDirectory=prowlarr"];
      };
    };

    mkArrVHost = port:
      fpLib.mkVirtualHost {
        inherit port;
        extraLocations."/api" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          extraConfig = ''
            auth_request off;
          '';
        };
      };
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      fireproof.homelab.dashboard.monitors = let
        mkMonitor = name: title: checkUrl: {
          inherit title checkUrl;
          url = "https://${name}.${cfg.domain}";
          icon = "sh:${name}";
          group = "downloads";
        };
        arrPing = name: "http://127.0.0.1:${toString config.services.${name}.settings.server.port}/ping";
      in {
        sonarr = mkMonitor "sonarr" "Sonarr" (arrPing "sonarr");
        radarr = mkMonitor "radarr" "Radarr" (arrPing "radarr");
        lidarr = mkMonitor "lidarr" "Lidarr" (arrPing "lidarr");
        prowlarr = mkMonitor "prowlarr" "Prowlarr" (arrPing "prowlarr");
        sabnzbd = mkMonitor "sabnzbd" "SABnzbd" "http://127.0.0.1:${toString config.services.sabnzbd.settings.misc.port}";
      };

      systemd.services =
        lib.genAttrs ["bazarr" "lidarr" "radarr" "sabnzbd" "sonarr"] (_: {
          unitConfig.RequiresMountsFor = ["/mnt/data"];
        })
        // {
          # Restore: stop the app, delete <db>*, `sqlite3 <db> < <name>.sql`, chown to the app's user.
          arr-db-dump = {
            serviceConfig = {
              Type = "oneshot";
              UMask = "0077";
            };
            # As the DB's owner: a root sqlite3 can leave a root-owned -shm the app can't open.
            script = lib.concatStrings (lib.mapAttrsToList (name: db: ''
                systemd-run --wait --pipe --quiet --collect ${lib.concatMapStringsSep " " (p: "-p ${p}") db.runAs} \
                  ${lib.getExe pkgs.sqlite} ${db.path} .dump > ${dumpDir}/${name}.sql.tmp
                mv ${dumpDir}/${name}.sql.tmp ${dumpDir}/${name}.sql
              '')
              dbs);
            preStart = "install -d -m700 ${dumpDir}";
          };
          # wants, not requires: a failed dump must not skip the file backup.
          restic-backups-homelab = {
            wants = ["arr-db-dump.service"];
            after = ["arr-db-dump.service"];
          };
        };

      # for linux ISOs
      # ids pinned: containers run as media via a numeric --user, which a null uid breaks.
      users.groups."${group}" = {
        gid = 988;
        members = [username];
      };
      users.users."${user}" = {
        inherit group;
        uid = 991;
        isSystemUser = true;
      };

      services = {
        oauth2-proxy.nginx.virtualHosts = {
          "radarr.${cfg.domain}".allowed_groups = ["arr"];
          "sonarr.${cfg.domain}".allowed_groups = ["arr"];
          "lidarr.${cfg.domain}".allowed_groups = ["arr"];
          "prowlarr.${cfg.domain}".allowed_groups = ["arr"];
          "sabnzbd.${cfg.domain}".allowed_groups = ["arr"];
          "bazarr.${cfg.domain}".allowed_groups = ["arr"];
        };
        nginx.virtualHosts = {
          "radarr.${cfg.domain}" = mkArrVHost 7878;
          "sonarr.${cfg.domain}" = mkArrVHost 8989;
          "lidarr.${cfg.domain}" = mkArrVHost 8686;
          "prowlarr.${cfg.domain}" = mkArrVHost 9696;
          "sabnzbd.${cfg.domain}" = mkArrVHost 8080;
          "bazarr.${cfg.domain}" = mkArrVHost config.services.bazarr.listenPort;
        };

        restic.backups.homelab = {
          paths = [
            "/var/lib/radarr"
            "/var/lib/sonarr"
            "/var/lib/lidarr"
            # DynamicUser: /var/lib/prowlarr is only a symlink, which restic stores as-is.
            "/var/lib/private/prowlarr"
            "/var/lib/sabnzbd"
            "/var/lib/bazarr"
            dumpDir
          ];
          exclude =
            lib.mapAttrsToList (_: db: "${db.resticPath}*") dbs
            ++ [
              # arrs logs and media cover
              "/var/lib/*/.config/*/logs.db*"
              "/var/lib/private/prowlarr/logs.db*"
              "/var/lib/*/.config/*/logs/"
              "/var/lib/*/.config/*/MediaCover/"
              "/var/lib/private/prowlarr/logs/"
              "/var/lib/sabnzbd/Downloads/"
              "/var/lib/sabnzbd/logs/"
            ];
        };

        sabnzbd = {
          inherit user group;
          enable = true;
          configFile = null;
        };
        radarr = {
          inherit user group;
          enable = true;
        };
        sonarr = {
          inherit user group;
          enable = true;
        };
        lidarr = {
          inherit user group;
          enable = true;
        };
        bazarr = {
          inherit user group;
          enable = true;
        };
        prowlarr.enable = true;
      };
    };
  };
}
