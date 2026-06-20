{
  flake.modules.nixos.restic = {
    pkgs,
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      environment.systemPackages = with pkgs; [
        restic
      ];

      age.secrets.restic-password.rekeyFile = ../../secrets/hosts/homelab/restic-password.age;
      age.secrets.restic-env.rekeyFile = ../../secrets/hosts/homelab/restic-env.age;

      services.restic.backups.homelab = {
        repository = "b2:fireproof-backup";
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
        passwordFile = "${config.age.secrets.restic-password.path}";
        environmentFile = "${config.age.secrets.restic-env.path}";
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 5"
          "--keep-monthly 12"
          "--keep-yearly 75"
        ];
      };

      # "Last successful backup" gauge for node_exporter's textfile collector.
      # ExecStartPost runs only on success, so a stale gauge means a backup that
      # silently didn't run — that's what the Grafana freshness alert watches.
      systemd.services.restic-backups-homelab.serviceConfig.ExecStartPost = lib.getExe (pkgs.writeShellApplication {
        name = "restic-freshness-gauge";
        runtimeInputs = [pkgs.coreutils];
        text = ''
          dir=/var/lib/node-exporter-textfile
          printf 'homelab_restic_last_success_timestamp_seconds %s\n' "$(date +%s)" >"$dir/restic.prom.tmp"
          mv "$dir/restic.prom.tmp" "$dir/restic.prom"
        '';
      });
    };
  };
}
