# Shared MariaDB engine for the homelab, mirroring the native postgres service
# (postgres.nix): always-on, with logical backups folded into the restic set. A
# service adds its own database the way postgres consumers do — append to
# services.mysql.ensureDatabases and services.mysqlBackup.databases. ensureUsers only
# does socket auth, so a containerized service that connects over TCP also provisions
# its password user in a `systemd.services.mysql.postStart = lib.mkAfter` hook (see
# grimmory.nix).
#
# bind-address + the docker0 firewall hole let container consumers reach it over the
# bridge gateway (host.docker.internal:host-gateway); native socket consumers ignore
# both. The firewall's default deny still blocks 3306 on the LAN/WAN NICs.
{
  flake.modules.nixos.mariadb = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      services.mysql = {
        enable = true;
        package = pkgs.mariadb;
        settings.mysqld.bind-address = "0.0.0.0";
      };

      services.mysqlBackup = {
        enable = true;
        singleTransaction = true; # consistent InnoDB dumps without locking
      };

      networking.firewall.interfaces."docker0".allowedTCPPorts = [3306];

      services.restic.backups.homelab.paths = [config.services.mysqlBackup.location];
    };
  };
}
