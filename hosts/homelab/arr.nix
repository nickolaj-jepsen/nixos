{
  config,
  username,
  ...
}: let
  user = "media";
  group = "media";

  mkVirtualHost = port: {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://localhost:${toString port}";
    };
    basicAuthFile = "${config.age.secrets.arr-basic-auth.path}";
  };
in {
  # for linux ISOs
  age.secrets = {
    arr-basic-auth = {
      rekeyFile = ../../secrets/hosts/homelab/basic-auth.age;
      owner = config.services.nginx.user;
      inherit (config.services.nginx) group;
    };
  };

  users.groups."${group}" = {
    members = [username];
  };
  users.users."${user}" = {
    inherit group;
    isSystemUser = true;
  };

  services = {
    nginx.virtualHosts = {
      "radarr.nickolaj.com" = mkVirtualHost 7878;
      "sonarr.nickolaj.com" = mkVirtualHost 8989;
      "prowlarr.nickolaj.com" = mkVirtualHost 9696;
      "sabnzbd.nickolaj.com" = mkVirtualHost 8080;
    };

    restic.backups.homelab.paths = [
      "/var/lib/radarr"
      "/var/lib/sonarr"
      "/var/lib/prowlarr"
      "/var/lib/sabnzbd"
    ];

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
    prowlarr.enable = true;
  };
}
