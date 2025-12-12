{
  config,
  lib,
  username,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  user = "media";
  group = "media";

  mkVirtualHost = port: {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://localhost:${toString port}";
    };
    locations."/api" = {
      proxyPass = "http://localhost:${toString port}";
      extraConfig = ''
        auth_request off;
      '';
    };
  };
in {
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
      "radarr.nickolaj.com".allowed_groups = ["arr"];
      "sonarr.nickolaj.com".allowed_groups = ["arr"];
      "prowlarr.nickolaj.com".allowed_groups = ["arr"];
      "sabnzbd.nickolaj.com".allowed_groups = ["arr"];
      "bazarr.nickolaj.com".allowed_groups = ["arr"];
    };
    nginx.virtualHosts = {
      "radarr.nickolaj.com" = mkVirtualHost 7878;
      "sonarr.nickolaj.com" = mkVirtualHost 8989;
      "prowlarr.nickolaj.com" = mkVirtualHost 9696;
      "sabnzbd.nickolaj.com" = mkVirtualHost 8080;
      "bazarr.nickolaj.com" = mkVirtualHost config.services.bazarr.listenPort;
    };

    restic.backups.homelab = {
      paths = [
        "/var/lib/radarr"
        "/var/lib/sonarr"
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
    };
    radarr = {
      inherit user group;
      enable = true;
    };
    sonarr = {
      inherit user group;
      enable = true;
    };
    bazarr = {
      inherit user group;
      enable = true;
    };
    prowlarr.enable = true;
  };
})
