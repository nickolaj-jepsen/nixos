{
  flake.modules.nixos.nextcloud = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.homelab;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      age.secrets.nextcloud-admin-pass = {
        rekeyFile = ../../secrets/hosts/homelab/nextcloud-admin-pass.age;
        owner = "nextcloud";
        group = "nextcloud";
      };
      age.secrets.discord-webhook-sys-info.rekeyFile = ../../secrets/hosts/homelab/discord-webhook-sys-info.age;

      services = {
        restic.backups.homelab.paths = [config.services.nextcloud.home];

        nginx.virtualHosts.${config.services.nextcloud.hostName} = {
          forceSSL = true;
          enableACME = true;
        };

        nextcloud = {
          package = pkgs.nextcloud33;
          enable = true;
          https = true;
          database.createLocally = true;
          hostName = "nextcloud.${cfg.domain}";
          config = {
            adminpassFile = "${config.age.secrets.nextcloud-admin-pass.path}";
            dbtype = "pgsql";
          };
          extraApps = {
            inherit (config.services.nextcloud.package.packages.apps) sociallogin;
          };
        };
      };

      # Daily healthcheck → #sys-info: catches the classic silent Nextcloud failures
      # (background cron stopped; setup checks flagging issues) that no host metric
      # reveals. Posts only when something is wrong.
      systemd.services.nextcloud-healthcheck = {
        description = "Nextcloud cron/setup healthcheck → Discord";
        after = ["phpfpm-nextcloud.service"];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.age.secrets.discord-webhook-sys-info.path;
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "nextcloud-healthcheck";
            runtimeInputs = [config.services.nextcloud.occ pkgs.jq pkgs.curl pkgs.coreutils];
            text = ''
              problems=""
              now=$(date +%s)
              lastcron=$(nextcloud-occ config:app:get core lastcron 2>/dev/null | tr -dc '0-9' || true)
              [ -n "$lastcron" ] || lastcron=0
              if [ "$lastcron" -gt 0 ] && [ "$((now - lastcron))" -gt 3600 ]; then
                problems="$problems cron has not run in $(( (now - lastcron) / 60 )) min;"
              fi
              # Confirm `occ setupchecks` exit semantics on the box; drop this branch if noisy.
              if ! nextcloud-occ setupchecks >/dev/null 2>&1; then
                problems="$problems setupchecks flagged issues;"
              fi
              if [ -n "$problems" ]; then
                jq -nc --arg c "Nextcloud healthcheck:$problems" '{content: $c}' \
                  | curl -fsS -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_SYS_INFO" >/dev/null
              fi
            '';
          });
        };
      };
      systemd.timers.nextcloud-healthcheck = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    };
  };
}
