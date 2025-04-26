{
  config,
  pkgs,
  ...
}: {
  age.secrets.nextcloud-admin-pass = {
    rekeyFile = ../../secrets/hosts/homelab/nextcloud-admin-pass.age;
    owner = "nextcloud";
    group = "nextcloud";
  };

  services = {
    restic.backups.homelab.paths = [config.services.nextcloud.home];

    nginx.virtualHosts.${config.services.nextcloud.hostName} = {
      forceSSL = true;
      enableACME = true;
    };

    nextcloud = {
      package = pkgs.nextcloud31;
      enable = true;
      https = true;
      database.createLocally = true;
      hostName = "nextcloud.nickolaj.com";
      config = {
        adminpassFile = "${config.age.secrets.nextcloud-admin-pass.path}";
        dbtype = "pgsql";
      };
      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps) sociallogin;
      };
    };
  };
}
