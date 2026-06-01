{
  config,
  lib,
  ...
}: {
  config = lib.mkIf config.fireproof.homelab.enable {
    services = {
      restic.backups.homelab.paths = [config.services.postgresqlBackup.location];

      postgresql = {
        enable = true;
        enableTCPIP = true;
        # The dawarich database requires PostGIS; without it pg_dumpall aborts
        # on that DB and no database backups are produced.
        extensions = ps: [ps.postgis];
        settings = {
          port = 5432;
        };
      };
      postgresqlBackup.enable = true;
    };
  };
}
