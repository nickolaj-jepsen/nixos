{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable {
  services = {
    restic.backups.homelab.paths = [config.services.postgresqlBackup.location];

    postgresql.enable = true;
    postgresqlBackup.enable = true;
  };
}
