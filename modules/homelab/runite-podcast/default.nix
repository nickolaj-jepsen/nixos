# runite-podcast: watches a Patreon podcast feed, downloads new episodes,
# normalizes tags and filenames, and publishes them into the Audiobookshelf
# podcast library. Built on the runite workflow framework, which is the real
# reason it exists — this is the framework's first outside consumer.
#
# The container, the migration barrier and the mount/identity constraints live
# in the app's own repo (`inputs.runite-podcast.nixosModules.default`), pinned
# together with the image digest they assume. This file is only the part that
# is true of *this host*: the domain, the SSO gate, the secret, the database
# and its identity, and the import cutoff.
#
# Postgres comes over the host's socket with peer authentication, so there is
# no database password anywhere: the container runs as uid `runite_podcast` and
# the default `local all all peer` line maps that to the role of the same name.
# Its *primary* group is `media` because mergerfs honours only the caller's
# primary gid, so a supplementary group would not grant write access to the
# 0775 media-owned library.
#
# Manual steps before `just switch`:
#   - `just secret-edit secrets/hosts/homelab/runite-podcast-env.age` with
#     PODCAST_FEED_CLUBFISH=<the Patreon RSS URL, including its auth token>.
#     One KEY=VALUE per line and never quote the value: docker's env-file
#     parser strips nothing, so quotes would end up inside the value. Nothing
#     sources this file in a shell, which is what makes the `&` in the feed URL
#     safe. No admin token: the console authenticates through this host's
#     oauth2-proxy, so there is no shared secret to rotate.
#   - `just secret-rekey`, which also `git add`s it — a secret that is not
#     tracked is invisible to `nix flake eval` and the build fails.
#   - Let CI publish an image, bump `nix/image.nix` in the app repo, then
#     `nix flake update runite-podcast` here.
#   - A DNS record for runite.<domain> pointing at this host.
#   - After the first publish, set the podcast library's
#     `autoScanCronExpression` in Audiobookshelf. It is null by default and
#     there is no built-in periodic scan, so *replaced* files are never noticed:
#     Audiobookshelf's watcher `change` handler is deliberately empty.
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

      # One line, never quoted: PODCAST_FEED_CLUBFISH. The feed URL carries the
      # subscriber token in its query string and appears inside every enclosure
      # URL, so this file is a credential in its own right. No `owner`: dockerd
      # reads it as root.
      age.secrets.runite-podcast-env.rekeyFile = ../../../secrets/hosts/homelab/runite-podcast-env.age;

      # The container depends on the daemon at boot; docker.nix defaults this off.
      virtualisation.docker.enableOnBoot = true;

      # Peer authentication's other half: an OS identity whose name matches the
      # role. Primary group media, for mergerfs.
      users.users.${db} = {
        inherit uid;
        group = "media";
        isSystemUser = true;
        description = "runite-podcast container";
      };

      # No `authentication` override: the nixpkgs default `local all all peer`
      # already maps OS ${db} to the role of the same name. No password, so no
      # second secret to keep in step with a DSN. postgresqlBackup picks the
      # database up on its own — postgres.nix sets no `databases`, so it runs
      # pg_dumpall.
      services.postgresql = fpLib.mkPostgresDB {name = db;};

      services.runite-podcast = {
        enable = true;
        pool = "/mnt/data";
        # /mnt/data/podcasts is created by audiobookshelf.nix, which owns it.
        gid = mediaGid;
        inherit uid port;
        dsn = "postgresql://${db}@/${db}?host=/run/postgresql";
        # postgresql.target rather than .service: it pulls in postgresql-setup,
        # which is what creates the role the DSN names.
        databaseUnits = ["postgresql.target"];
        # Two years of back catalogue: 198 episodes, ~17 GB. `scan` fires
        # everything published on or after this, 25 per hourly tick and four
        # downloads at a time, so it fills in over a few hours. Lowering this
        # again is how the archive grows; anything older needs the one-shot
        # `podcast import-history`, which is the only path to pre-cutoff keys.
        since = "2024-08-01";
        environmentFiles = [config.age.secrets.runite-podcast-env.path];
        executorId = "homelab";
        # oauth2-proxy forwards the address as X-Email; the console reads that
        # and this list is what makes one of those identities an admin. The
        # value is the zitadel UserName, which is what reaches the header.
        admins = ["nickolaj1177@gmail.com"];
        # alloy.nix receives OTLP on the docker bridge. Traces are accepted
        # there but not yet forwarded — Tempo credentials are a manual secret
        # step, noted in that file.
        otlpEndpoint = "http://host.docker.internal:4318";
        # No registryLogin: the ghcr package is public, like the repo it is
        # built from, so neither the container nor the migration unit needs a
        # pull credential.
      };

      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["arr"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        extraLocations = {
          # The SPA is mounted at /ui only; there is no route at /.
          "= /".return = "302 /ui";
          # Ledger-change hints. SSE needs buffering off or events arrive in
          # batches whenever nginx decides to flush.
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

      # No restic path. The container keeps no state outside the pool; the
      # ledger is in the postgresqlBackup dump; and the media is re-downloadable
      # from the feed, which is the whole point of the app.
    };
  };
}
