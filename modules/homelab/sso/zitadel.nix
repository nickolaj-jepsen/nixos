{
  flake.modules.nixos.sso-zitadel = {
    config,
    lib,
    pkgs,
    fpLib,
    ...
  }: let
    port = 9190;
    zitadelDomain = "sso.${config.fireproof.homelab.domain}";
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      age.secrets.zitadel-master = {
        rekeyFile = ../../../secrets/hosts/homelab/zitadel-master.age;
        owner = config.services.zitadel.user;
      };

      services.nginx.virtualHosts."${zitadelDomain}" = fpLib.mkVirtualHost {
        inherit port;
        extraConfig = ''
          grpc_pass grpc://127.0.0.1:${toString port};
          grpc_set_header Host $host:$server_port;
        '';
      };

      services.postgresql = fpLib.mkPostgresDB {
        name = "zitadel";
        login = true;
      };

      # The upstream zitadel module orders the unit only after basic.target (unlike
      # every other DB consumer here, whose upstream modules order after
      # postgresql.target), so on boot it races PostgreSQL and dies with SQLSTATE
      # 57P03 ("database system is starting up"). After 5 fast retries it hits the
      # start limit and gives up permanently, which cascades into oauth2-proxy (SSO
      # down -> 502) and a 500 on every vhost behind it. postgresql.target is
      # reached only after postgresql.service (Type=notify, i.e. accepting
      # connections) AND postgresql-setup.service (which creates the zitadel db/user
      # via mkPostgresDB), so it is the correct readiness barrier. RestartSec + a
      # looser start limit are belt-and-suspenders for any other transient.
      systemd.services.zitadel = {
        after = ["postgresql.target"];
        requires = ["postgresql.target"];
        startLimitIntervalSec = 120;
        startLimitBurst = 10;
        serviceConfig.RestartSec = "5s";
      };

      services.zitadel = {
        enable = true;
        package = pkgs.unstable.zitadel;
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
  };
}
