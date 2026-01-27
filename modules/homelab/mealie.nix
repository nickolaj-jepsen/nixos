{
  config,
  lib,
  pkgsUnstable,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "mealie.nickolaj.com";
  port = 9000;
in {
  users.users.mealie = {
    isSystemUser = true;
    group = "mealie";
  };
  users.groups.mealie = {};

  age.secrets.mealie-oidc-env = {
    rekeyFile = ../../secrets/hosts/homelab/mealie-oidc-env.age;
    owner = "mealie";
  };

  services.mealie = {
    enable = true;
    inherit port;
    package = pkgsUnstable.mealie;
    settings = {
      # Base URL for Mealie
      BASE_URL = "https://${domain}";

      # Authentication - OIDC V2
      ALLOW_SIGNUP = "false";
      ALLOW_PASSWORD_LOGIN = "false";
      OIDC_AUTH_ENABLED = "true";
      OIDC_SIGNUP_ENABLED = "true";
      OIDC_CONFIGURATION_URL = "https://sso.nickolaj.com/.well-known/openid-configuration";
      OIDC_AUTO_REDIRECT = "true";
      OIDC_PROVIDER_NAME = "Zitadel";
      OIDC_USER_GROUP = "default";
      OIDC_ADMIN_GROUP = "admin";

      # Database - Mealie supports Postgres
      DB_ENGINE = "postgres";
      POSTGRES_USER = "mealie";
      POSTGRES_DB = "mealie";
      POSTGRES_SERVER = "127.0.0.1";
      POSTGRES_PORT = "5432";
    };
    credentialsFile = config.age.secrets.mealie-oidc-env.path;
  };

  services.postgresql = {
    ensureDatabases = ["mealie"];
    ensureUsers = [
      {
        name = "mealie";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkAfter ''
      # type  database  user    address       auth-method
      host    mealie    mealie  127.0.0.1/32  trust
    '';
  };

  # Database backups are handled globally by services.postgresqlBackup.enable = true
  # We just need to ensure the state directory (images, etc) is backed up by restic
  services.restic.backups.homelab.paths = [
    "/var/lib/mealie"
  ];

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
    };
  };
})
