{config, ...}: {
  services = {
    restic.backups.homelab.paths = [config.services.postgresqlBackup.location];

    postgresql.enable = true;
    postgresqlBackup.enable = true;
  };
}