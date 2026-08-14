{
  flake.modules.nixos.bm-cms = {
    config,
    lib,
    fpLib,
    ...
  }: let
    # The customer's own domain, not fireproof.homelab.domain.
    domain = "cms.bmtomrermontage.dk";
    port = 3000;
    db = "bmcms";
    envFile = config.age.secrets.bm-cms-env.path;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      # No DEPLOY_HOOK_URL: CMS just warns, publish looks fine but never rebuilds.
      # DATABASE_PASSWORD must match DATABASE_URI's password (nix can't derive it).
      age.secrets.bm-cms-env = {
        rekeyFile = ../../../secrets/hosts/homelab/bm-cms-env.age;
        owner = "postgres";
      };
      age.secrets.ghcr-pull-token.rekeyFile = ../../../secrets/hosts/homelab/ghcr-pull-token.age;

      virtualisation.docker.enableOnBoot = true;

      services.postgresql = fpLib.mkPostgresDB {
        name = db;
        login = true;
        # uid 1001 (container) can't peer-auth; mkBefore beats default peer rule.
        authentication = lib.mkBefore "local ${db} ${db} scram-sha-256";
      };

      systemd.services.postgresql-setup.postStart = lib.mkAfter ''
        set -a
        . ${envFile}
        set +a
        psql -tAc "ALTER ROLE ${db} WITH PASSWORD '$DATABASE_PASSWORD'"
      '';

      virtualisation.oci-containers.containers.bm-cms = {
        image = import ./_image.nix;
        login = {
          registry = "ghcr.io";
          username = "nickolaj-jepsen";
          passwordFile = config.age.secrets.ghcr-pull-token.path;
        };
        # Must exactly match the browser origin (scheme+host) or every write 403s.
        environment.SERVER_URL = "https://${domain}";
        environmentFiles = [envFile];
        ports = ["127.0.0.1:${toString port}:${toString port}"];
        volumes = ["/run/postgresql:/run/postgresql"];
      };

      # Retries: can still start before postgresql-setup finishes the role password.
      systemd.services.docker-bm-cms = {
        after = ["postgresql.target"];
        requires = ["postgresql.target"];
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = "15s";
        };
      };

      services.nginx.appendHttpConfig = ''
        limit_req_zone $binary_remote_addr zone=bmcmslogin:10m rate=5r/m;
      '';

      services.nginx.virtualHosts."${domain}" =
        fpLib.mkVirtualHost {
          inherit port;
          extraLocations."/api/users/login" = {
            proxyPass = "http://127.0.0.1:${toString port}";
            extraConfig = ''
              limit_req zone=bmcmslogin burst=5 nodelay;
            '';
          };
        }
        // {
          # add_header doesn't merge across levels; login has none of its own.
          extraConfig = ''
            add_header X-Robots-Tag "noindex, nofollow" always;
          '';
        };
    };
  };
}
