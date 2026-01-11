{
  config,
  pkgsUnstable,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  port = 9190;
  rootDomain = "nickolaj.com";
  zitadelDomain = "sso.${rootDomain}";
  oathproxyDomain = "oauth2-proxy.${rootDomain}";
in {
  age.secrets.zitadel-master = {
    rekeyFile = ../../secrets/hosts/homelab/zitadel-master.age;
    owner = config.services.zitadel.user;
  };
  age.secrets.oauth2-proxy = {
    rekeyFile = ../../secrets/hosts/homelab/oauth2-proxy-keyfile.age;
    owner = "oauth2-proxy";
  };

  services.nginx.virtualHosts."${zitadelDomain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      extraConfig = ''
        grpc_pass grpc://127.0.0.1:${toString port};
        grpc_set_header Host $host:$server_port;
      '';
    };
  };
  services.nginx.virtualHosts."${oathproxyDomain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyWebsockets = true;
      proxyPass = "http://127.0.0.1:4180";
    };
  };

  services.postgresql = {
    ensureDatabases = ["zitadel"];
    ensureUsers = [
      {
        name = "zitadel";
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };

  services.zitadel = {
    enable = true;
    package = pkgsUnstable.zitadel;
    masterKeyFile = config.age.secrets.zitadel-master.path;
    settings = {
      Port = port;
      Database.postgres = {
        Host = "/var/run/postgresql/";
        Port = 5432;
        Database = "zitadel";
        User = {
          Username = "zitadel";
          SSL.Mode = "disable";
        };
        Admin = {
          Username = "zitadel";
          SSL.Mode = "disable";
          ExistingDatabase = "zitadel";
        };
      };
      ExternalDomain = zitadelDomain;
      ExternalPort = 443;
      ExternalSecure = true;
    };
    steps.FirstInstance = {
      InstanceName = "Fireproof Auth";
      Org = {
        Name = "Fireproof Auth";
        Human = {
          UserName = "nickolaj1177@gmail.com";
          FirstName = "Nickolaj";
          LastName = "Jepsen";
          Email.Verified = true;
          Password = "Password1!";
          PasswordChangeRequired = true;
        };
      };
      LoginPolicy.AllowRegister = false;
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    reverseProxy = true;
    redirectURL = "https://${oathproxyDomain}/oauth2/callback";
    validateURL = "https://${zitadelDomain}/oauth2/";
    oidcIssuerUrl = "https://${zitadelDomain}:443";
    keyFile = config.age.secrets.oauth2-proxy.path;
    passBasicAuth = true;
    setXauthrequest = true;
    nginx.domain = oathproxyDomain;
    email.domains = ["*"];
    extraConfig = {
      whitelist-domain = ".${rootDomain}";
      cookie-domain = ".${rootDomain}";
    };
  };
})
