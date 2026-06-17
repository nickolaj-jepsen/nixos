{
  flake.aspectTags.arr = ["homelab"];
  flake.modules.nixos.arr = {
    config,
    lib,
    fpLib,
    ...
  }: let
    inherit (config.fireproof) username;
    cfg = config.fireproof.homelab;
    user = "media";
    group = "media";

    mkArrVHost = port:
      fpLib.mkVirtualHost {
        inherit port;
        extraLocations."/api" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          extraConfig = ''
            auth_request off;
          '';
        };
      };
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      # for linux ISOs
      users.groups."${group}" = {
        members = [username];
      };
      users.users."${user}" = {
        inherit group;
        isSystemUser = true;
      };

      services = {
        oauth2-proxy.nginx.virtualHosts = {
          "radarr.${cfg.domain}".allowed_groups = ["arr"];
          "sonarr.${cfg.domain}".allowed_groups = ["arr"];
          "lidarr.${cfg.domain}".allowed_groups = ["arr"];
          "prowlarr.${cfg.domain}".allowed_groups = ["arr"];
          "sabnzbd.${cfg.domain}".allowed_groups = ["arr"];
          "bazarr.${cfg.domain}".allowed_groups = ["arr"];
        };
        nginx.virtualHosts = {
          "radarr.${cfg.domain}" = mkArrVHost 7878;
          "sonarr.${cfg.domain}" = mkArrVHost 8989;
          "lidarr.${cfg.domain}" = mkArrVHost 8686;
          "prowlarr.${cfg.domain}" = mkArrVHost 9696;
          "sabnzbd.${cfg.domain}" = mkArrVHost 8080;
          "bazarr.${cfg.domain}" = mkArrVHost config.services.bazarr.listenPort;
        };

        restic.backups.homelab = {
          paths = [
            "/var/lib/radarr"
            "/var/lib/sonarr"
            "/var/lib/lidarr"
            "/var/lib/prowlarr"
            "/var/lib/sabnzbd"
            "/var/lib/bazarr"
          ];
          exclude = [
            # arrs logs and media cover
            "/var/lib/*/.config/*/logs/"
            "/var/lib/*/.config/*/MediaCover/"
            "/var/lib/sabnzbd/Downloads/"
            "/var/lib/sabnzbd/logs/"
          ];
        };

        sabnzbd = {
          inherit user group;
          enable = true;
          configFile = null;
        };
        radarr = {
          inherit user group;
          enable = true;
        };
        sonarr = {
          inherit user group;
          enable = true;
        };
        lidarr = {
          inherit user group;
          enable = true;
        };
        bazarr = {
          inherit user group;
          enable = true;
        };
        prowlarr.enable = true;
      };
    };
  };
}
