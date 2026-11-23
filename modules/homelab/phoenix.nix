{fpLib, ...}: {
  flake.modules.nixos.phoenix = {
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "phoenix.${cfg.domain}";
    port = 6006;
    stateDir = "/var/lib/phoenix/data";
    pgSocket = "/run/postgresql";
    # Match the nonroot image so PostgreSQL can authenticate the container via peer.
    uid = 65532;
  in {
    config = lib.mkIf (cfg.enable && cfg.phoenix.enable) {
      age.secrets.phoenix-env.rekeyFile = ../../secrets/hosts/homelab/phoenix-env.age;
      virtualisation.docker.enableOnBoot = true;

      users.users.phoenix = {
        isSystemUser = true;
        group = "phoenix";
        inherit uid;
      };
      users.groups.phoenix.gid = uid;
      services.postgresql = fpLib.mkPostgresDB {
        name = "phoenix";
        login = true;
      };
      systemd.services.docker-phoenix = {
        # Setup provisions the database and role on first activation.
        requires = ["postgresql.service" "postgresql-setup.service"];
        after = ["postgresql.service" "postgresql-setup.service" "systemd-tmpfiles-setup.service"];
      };
      systemd.tmpfiles.rules = ["d ${stateDir} 0700 phoenix phoenix -"];
      virtualisation.oci-containers.containers.phoenix = {
        image = "arizephoenix/phoenix:version-22.0.1-nonroot@sha256:53bbfd959a5fa32680bf81607d4ba548d87a87133307c3feb9d2076e70b597ea";
        environment = {
          PHOENIX_WORKING_DIR = "/data";
          PHOENIX_SQL_DATABASE_URL = "postgresql:///phoenix?host=${pgSocket}&user=phoenix";
          PHOENIX_ENABLE_AUTH = "true";
          PHOENIX_USE_SECURE_COOKIES = "true";
          PHOENIX_CSRF_TRUSTED_ORIGINS = "https://${domain}";
          PHOENIX_DEFAULT_RETENTION_POLICY_DAYS = "30";
        };
        environmentFiles = [config.age.secrets.phoenix-env.path];
        user = "${toString uid}:${toString uid}";
        volumes = ["${stateDir}:/data" "${pgSocket}:${pgSocket}:ro"];
        ports = ["127.0.0.1:${toString port}:6006"];
        extraOptions = ["--cap-drop=ALL" "--security-opt=no-new-privileges"];
      };

      # Same listener for the UI and bearer-authenticated OTLP: no OAuth in front of it.
      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true;
        extraConfig = "client_max_body_size 16m;";
      };

      fireproof.homelab.dashboard.monitors.phoenix = {
        title = "Arize Phoenix";
        url = "https://${domain}";
        checkUrl = "http://127.0.0.1:${toString port}/readyz";
        icon = "si:opentelemetry";
        group = "infra";
      };
    };
  };
}
