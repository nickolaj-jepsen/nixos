{
  config,
  lib,
  ...
}: let
  domain = "wg.nickolaj.com";
in {
  config = lib.mkIf config.fireproof.homelab.enable {
    age.secrets.wg-access-server = {
      rekeyFile = ../../secrets/hosts/homelab/wg-access-server.age;
    };

    services.wg-access-server = {
      enable = true;
      secretsFile = config.age.secrets.wg-access-server.path;
      settings = {
        storage = "postgresql://wgaccess@localhost:5432/wgaccess?sslmode=disable";
        externalHost = domain;
        dns = {
          enabled = true;
          upstream = ["1.1.1.1" "8.8.8.8"];
        };
        auth = {
          oidc = {
            name = "Zitadel";
            issuer = "https://sso.nickolaj.com:443";
            clientID = "357588045165297675";
            redirectURL = "https://${domain}/callback";
            scopes = ["openid" "profile" "email" "groups"];
            claimMapping = {
              admin = "'admin' in groups";
              access = "'vpn' in groups";
            };
          };
        };
      };
    };

    services.nginx.virtualHosts."${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8000";
        proxyWebsockets = true;
      };
    };

    services.postgresql = {
      ensureDatabases = ["wgaccess"];
      ensureUsers = [
        {
          name = "wgaccess";
          ensureDBOwnership = true;
          ensureClauses.login = true;
        }
      ];
      authentication = lib.mkBefore ''
        # type  database  user      address       auth-method
        host    wgaccess  wgaccess  127.0.0.1/32  trust
        host    wgaccess  wgaccess  ::1/128       trust
      '';
    };

    networking.firewall = {
      allowedUDPPorts = [51820];
      # Trust the wireguard interface to allow traffic to be forwarded
      trustedInterfaces = ["wg0"];
      # Often required for WireGuard to work correctly with reverse path filtering
      checkReversePath = false;
    };
  };
}
