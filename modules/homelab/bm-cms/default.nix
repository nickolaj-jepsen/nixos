# PayloadCMS admin UI for bmtomrermontage.dk, as an OCI container (Docker-only
# upstream). Site builds fetch published content from this CMS's API at build
# time; the deployed site never calls it, so the public site has no runtime
# dependency on this host — if the container is down, editing and site builds
# stop, the live site does not. Draft previews live in ../bm-preview.
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
      # KEY=value: DATABASE_URI, DATABASE_PASSWORD, PAYLOAD_SECRET, DEPLOY_HOOK_URL.
      # DEPLOY_HOOK_URL is the Workers Builds hook a publish POSTs; the URL is
      # the credential. Without it the CMS logs a warning and never triggers a
      # site build, which looks exactly like a working publish.
      # DATABASE_PASSWORD must repeat the password inside DATABASE_URI — nix can't
      # read the secret to derive one from the other. owner=postgres is for the
      # postgresql-setup hook below.
      age.secrets.bm-cms-env = {
        rekeyFile = ../../../secrets/hosts/homelab/bm-cms-env.age;
        owner = "postgres";
      };
      # Classic PAT with read:packages — the GHCR package is private.
      age.secrets.ghcr-pull-token.rekeyFile = ../../../secrets/hosts/homelab/ghcr-pull-token.age;

      # The container depends on the daemon at boot; docker.nix defaults this off.
      virtualisation.docker.enableOnBoot = true;

      services.postgresql = fpLib.mkPostgresDB {
        name = db;
        login = true;
        # Peer auth can't map the container's uid 1001 to this role, so it needs a
        # password; mkBefore puts this ahead of the default `local all all peer`.
        authentication = lib.mkBefore "local ${db} ${db} scram-sha-256";
      };

      # ensureUsers can't set a password; idempotent, so rotating the secret takes
      # effect on the next postgresql restart.
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
        # Payload's CSRF allowlist, and nothing else. It has to match the origin
        # the browser actually sends — scheme and host, no trailing slash — or
        # every write 403s. The app falls back to this same string, but the
        # fallback is a literal in the repo that nothing keeps in step with
        # `domain` here.
        environment.SERVER_URL = "https://${domain}";
        environmentFiles = [envFile];
        ports = ["127.0.0.1:${toString port}:${toString port}"];
        # Host Postgres over its socket instead of TCP.
        volumes = ["/run/postgresql:/run/postgresql"];
      };

      # postgresql.target (not .service) pulls in postgresql-setup, which sets the
      # role password Payload needs on its first connect; retry rather than fail
      # the boot if it still outraces a cold Postgres.
      systemd.services.docker-bm-cms = {
        after = ["postgresql.target"];
        requires = ["postgresql.target"];
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = "15s";
        };
      };

      # Payload's own maxLoginAttempts/lockTime sits on top of this.
      services.nginx.appendHttpConfig = ''
        limit_req_zone $binary_remote_addr zone=bmcmslogin:10m rate=5r/m;
      '';

      # No oauth2-proxy gate: the customer has no Zitadel account.
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
          # Server level: nginx add_header doesn't merge across levels, and the
          # login location sets none of its own.
          extraConfig = ''
            add_header X-Robots-Tag "noindex, nofollow" always;
          '';
        };

      # No restic path: no state in the container, and the DB is already in the
      # postgresqlBackup dump.
    };
  };
}
