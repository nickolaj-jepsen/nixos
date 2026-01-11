{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "freshrss.nickolaj.com";
in {
  services.freshrss = {
    enable = true;
    baseUrl = "https://${domain}";
    virtualHost = domain;
    database = {
      type = "pgsql";
      host = "/var/run/postgresql/";
      user = "freshrss";
      name = "freshrss";
    };
    authType = "http_auth";
    defaultUser = "nickolaj1177@gmail.com";
  };

  services.postgresql = {
    ensureDatabases = ["freshrss"];
    ensureUsers = [
      {
        name = "freshrss";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };

  services.oauth2-proxy.nginx.virtualHosts = {
    "${domain}" = {
      allowed_groups = ["default"];
    };
  };

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;
    locations."~ ^.+?\\.php(/.*)?$" = {
      extraConfig = lib.mkAfter ''
        auth_request_set $email  $upstream_http_x_auth_request_email;
        fastcgi_param REMOTE_USER $email;
      '';
    };
  };

  services.restic.backups.homelab.paths = [
    "/var/lib/freshrss"
  ];
})
