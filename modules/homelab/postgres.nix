{
  flake.modules.nixos.postgres = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      services = {
        restic.backups.homelab.paths = [config.services.postgresqlBackup.location];

        postgresql = {
          enable = true;
          # The dawarich database requires PostGIS; without it pg_dumpall aborts
          # on that DB and no database backups are produced.
          extensions = ps: [ps.postgis];
          settings = {
            # Data lives on the SSD mirror and totals ~2.5 GB, so 1 GB of buffers holds the hot set.
            shared_buffers = "1GB";
            effective_cache_size = "8GB";
            maintenance_work_mem = "256MB";
            random_page_cost = 1.1;
            effective_io_concurrency = 200;

            # Fewer, smaller checkpoints: the checkpointer is the top steady writer on the SSDs.
            checkpoint_timeout = "15min";
            max_wal_size = "4GB";
            wal_compression = "zstd";
          };
        };
        postgresqlBackup = {
          enable = true;
          # Run by restic instead, so each snapshot pairs the files with a same-moment dump.
          startAt = [];
        };
      };

      systemd.services = {
        # wants, not requires: a failed dump must not skip the file backup.
        restic-backups-homelab = {
          wants = ["postgresqlBackup.service"];
          after = ["postgresqlBackup.service"];
        };
        # Upstream only Requires= the target, so restic's Persistent catch-up at boot would dump before postgres is up.
        postgresqlBackup.after = ["postgresql.target"];
      };
    };
  };
}
