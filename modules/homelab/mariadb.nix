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
        # Pinned major: a datadir can't be downgraded, so bump deliberately and run mariadb-upgrade.
        package = pkgs.mariadb_114;
        settings.mysqld = {
          bind-address = "0.0.0.0";
          # Docker bridge IPs have no PTR record; each lookup stalls a new connection ~15 s.
          skip-name-resolve = true;
        };
      };

      services.mysqlBackup = {
        enable = true;
        singleTransaction = true; # consistent InnoDB dumps without locking
      };

      networking.firewall.interfaces."docker0".allowedTCPPorts = [3306];

      services.restic.backups.homelab.paths = [config.services.mysqlBackup.location];

      # Run by restic instead of its own timer (see postgres.nix).
      systemd.timers.mysql-backup.enable = false;
      systemd.services = {
        restic-backups-homelab = {
          wants = ["mysql-backup.service"];
          after = ["mysql-backup.service"];
        };
        # Upstream has no ordering on mysql, so restic's Persistent catch-up at boot would dump before it is up.
        mysql-backup.after = ["mysql.service"];
      };
    };
  };
}
