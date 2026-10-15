# bind-address 0.0.0.0 relies on the firewall's default deny to keep 3306 off the
# LAN/WAN NICs; docker0 is the only hole. Adding a database: docs/homelab.md.
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

      # Run by restic instead, so each snapshot pairs the files with a same-moment dump.
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
