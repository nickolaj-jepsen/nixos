{fpLib, ...}: {
  flake.modules.nixos.navidrome = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "navidrome.${cfg.domain}";
    port = 4533;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      systemd.services.navidrome.unitConfig.RequiresMountsFor = ["/mnt/data"];

      age.secrets.navidrome-env.rekeyFile = ../../secrets/hosts/homelab/navidrome-env.age;

      services.restic.backups.homelab.paths = ["/var/lib/navidrome"];

      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["default"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true;
        extraConfig = ''
          auth_request_set $email  $upstream_http_x_auth_request_email;
          proxy_set_header Remote-User $email;
        '';
        extraLocations."^~ /rest" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          proxyWebsockets = true;
          # Ungated: navidrome trusts Remote-User from nginx, so drop the client's.
          extraConfig = ''
            auth_request off;
            proxy_set_header Remote-User "";
          '';
        };
      };

      services.navidrome = {
        enable = true;
        package = pkgs.unstable.navidrome;
        user = "media";
        group = "media";
        environmentFile = config.age.secrets.navidrome-env.path;
        settings = {
          Address = "127.0.0.1";
          Port = port;
          MusicFolder = "/mnt/data/music";
          ScanSchedule = "@every 1m";
          LogLevel = "info";
          "ExtAuth.Enabled" = true;
          "ExtAuth.TrustedSources" = "127.0.0.1/32";
          "ExtAuth.UserHeader" = "Remote-User";
        };
      };

      systemd.tmpfiles.rules = [
        "d /mnt/data/music 0775 media media -"
        "Z /var/lib/navidrome 0750 media media -"
      ];
    };
  };
}
