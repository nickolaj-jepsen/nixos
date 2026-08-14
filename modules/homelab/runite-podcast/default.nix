# Manual steps before `just switch`:
#   - `just secret-edit secrets/hosts/homelab/runite-podcast-env.age`:
#     PODCAST_FEED_CLUBFISH=<url>, unquoted
#   - `just secret-rekey`
#   - bump `nix/image.nix` upstream, then `nix flake update runite-podcast`
#   - DNS record for runite.<domain>
#   - after first publish, set podcast library's autoScanCronExpression in ABS
{
  flake.modules.nixos.runite-podcast = {
    config,
    lib,
    inputs,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "runite.${cfg.domain}";
    port = 8646;
    db = "runite_podcast";
    uid = 2001;
    mediaGid = config.users.groups.media.gid;
  in {
    imports = [inputs.runite-podcast.nixosModules.default];

    config = lib.mkIf config.fireproof.homelab.enable {
      assertions = [
        {
          assertion = mediaGid != null;
          message = ''
            runite-podcast needs media's gid at eval time; arr.nix must keep it
            pinned rather than dynamically allocated.

            Pin whatever the host already uses — changing media's gid would
            orphan every file jellyfin, sonarr, navidrome and audiobookshelf
            already own.
          '';
        }
      ];

      age.secrets.runite-podcast-env.rekeyFile = ../../../secrets/hosts/homelab/runite-podcast-env.age;

      virtualisation.docker.enableOnBoot = true;

      # Primary group media: mergerfs only honours the caller's primary gid.
      users.users.${db} = {
        inherit uid;
        group = "media";
        isSystemUser = true;
        description = "runite-podcast container";
      };

      services.postgresql = fpLib.mkPostgresDB {name = db;};

      services.runite-podcast = {
        enable = true;
        pool = "/mnt/data";
        gid = mediaGid;
        inherit uid port;
        dsn = "postgresql://${db}@/${db}?host=/run/postgresql";
        databaseUnits = ["postgresql.target"];
        # ~2yr back (198 eps, ~17GB); older needs one-shot podcast import-history.
        since = "2024-08-01";
        environmentFiles = [config.age.secrets.runite-podcast-env.path];
        executorId = "homelab";
        # Must match oauth2-proxy's X-Email header, not an app username.
        admins = ["nickolaj1177@gmail.com"];
        # Set here but not yet forwarded to Tempo — see alloy.nix.
        otlpEndpoint = "http://host.docker.internal:4318";
      };

      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["arr"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        extraLocations = {
          "= /".return = "302 /ui";
          # SSE: needs buffering off or nginx batches on its own flush schedule.
          "/api/ui/events" = {
            proxyPass = "http://127.0.0.1:${toString port}";
            extraConfig = ''
              proxy_buffering off;
              proxy_cache off;
              proxy_read_timeout 24h;
            '';
          };
        };
      };
    };
  };
}
