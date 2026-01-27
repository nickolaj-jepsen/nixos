{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable {
  services = {
    restic.backups.homelab.paths = [config.services.postgresqlBackup.location];

    postgresql = {
      enable = true;
      enableTCPIP = true;
      settings = {
        port = 5432;
      };
    };
    postgresqlBackup.enable = true;
  };
}
