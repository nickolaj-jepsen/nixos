{
  config,
  pkgsUnstable,
  lib,
  ...
}: let
  port = 9190;
  zitadelDomain = "sso.nickolaj.com";
in {
  config = lib.mkIf config.fireproof.homelab.enable {
    age.secrets.zitadel-master = {
      rekeyFile = ../../../secrets/hosts/homelab/zitadel-master.age;
      owner = config.services.zitadel.user;
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
  };
}
